# Zig 0.17 for AI Agents — from 0.15.x knowledge to 0.17.0

This document upgrades an AI coding agent whose reliable Zig knowledge ends at
**0.15.x** to a working command of **Zig 0.17.0** (tagged 2026-10-02). It
assumes you know **nothing** about 0.16. Everything here describes the final
0.17.0 state; where 0.16 introduced an API that 0.17 then changed again, only
the 0.17 form is taught, with the 0.16 spelling given so you can recognise and
migrate it.

**How it was built.** The 0.16 material is consolidated from four project
references that each survived a real 0.15 → 0.16 port. The 0.17 material
comes from the official 0.17.0 release notes, a diff of the 0.16.0 and 0.17.0
standard libraries and language references, `git log 0.16.0..0.17.0` of the
Zig repository, three community migration guides, and several hundred probe
programs compiled with **both** the 0.16.0 and 0.17.0 compilers on
aarch64-macos. Every API spelling in this file was compiled against 0.17.0
unless it is explicitly marked *unverified*. Where the official release notes
are wrong, this document says so and gives the shipped form.

**Authority order when sources disagree:** the installed 0.17.0 standard
library source → a five-line probe compiled with `zig test` → this document →
the release notes → your memory. Your memory is the least reliable source for
anything I/O-, allocator-, reflection- or build-related.

```bash
zig version                      # must print 0.17.0 (if it prints 0.16.0, see below)
zig env                          # .std_dir is the standard library source
grep -n 'pub fn readFileAlloc' "$(zig env | sed -n 's/.*\.std_dir = "\(.*\)".*/\1/p')/Io/Dir.zig"
zig test probe.zig               # settle any doubt with a probe
```

If `zig version` prints an older Zig right after 0.17 was installed, the
shell's `PATH` was captured before the install (common with version managers
such as mise and long-lived editor or agent sessions). Put 0.17 first:
`export PATH="$(mise where zig@0.17.0):$PATH"`, or open a new login shell.

---

## Contents

0. [Agent protocol (read first)](#0-agent-protocol-read-first)
   - [0.1 All in, one way, timeless](#01-all-in-one-way-timeless)
1. [Version timeline and toolchain facts](#1-version-timeline-and-toolchain-facts)
2. [Reflexes that no longer compile (0.15 → 0.17)](#2-reflexes-that-no-longer-compile-015--017)
3. [0.16 → 0.17 at a glance](#3-016--017-at-a-glance)
4. [Traps that compile (silent behaviour changes)](#4-traps-that-compile-silent-behaviour-changes)
5. [Language](#5-language)
6. [Reflection: `@typeInfo`, `std.lang.Type`, type-creating builtins](#6-reflection-typeinfo-stdlangtype-type-creating-builtins)
7. [`std.Io`: I/O as an interface](#7-stdio-io-as-an-interface)
8. [`main`, arguments, environment](#8-main-arguments-environment)
9. [Writers, readers, `Io.Limit`](#9-writers-readers-iolimit)
10. [Files and directories](#10-files-and-directories)
11. [Processes](#11-processes)
12. [Networking and HTTP](#12-networking-and-http)
13. [Concurrency, sync, time, entropy](#13-concurrency-sync-time-entropy)
14. [Allocators](#14-allocators)
15. [Containers](#15-containers)
16. [Strings, `std.mem`, formatting](#16-strings-stdmem-formatting)
17. [ZON and JSON](#17-zon-and-json)
18. [The POSIX and libc layer](#18-the-posix-and-libc-layer)
19. [Panics, debugging, tests, fuzzing](#19-panics-debugging-tests-fuzzing)
20. [The build system](#20-the-build-system)
21. [Compiler, linker, toolchain, targets](#21-compiler-linker-toolchain-targets)
22. [Compile-error decoder](#22-compile-error-decoder)
23. [Migration playbook and grep sweep](#23-migration-playbook-and-grep-sweep)
24. [Known 0.17.0 bugs and release-note errata](#24-known-0170-bugs-and-release-note-errata)
25. [Canonical 0.17 patterns (copy these)](#25-canonical-017-patterns-copy-these)

---

## 0. Agent protocol (read first)

You are writing or migrating Zig for **0.17.0**. Your pretrained Zig is
mostly 0.14/0.15. Most of it no longer compiles. Follow these rules:

1. **Do not write Zig from memory for I/O, allocation, containers,
   formatting-to-memory, reflection, or `build.zig`.** Use §25 and the section
   for the API family. When this document is silent, read the installed std
   source (`zig env` → `std_dir`) or compile a probe.
2. **Compile early and often.** `zig build` / `zig test` reports errors
   lazily, often one per build for `build.zig`. Treat the first error as a
   probe, fix one *API family* at a time, recompile, repeat.
3. **Migrate `build.zig` first.** A broken `build.zig` (yours *or a
   dependency's*) stops the build before any of your source compiles.
4. **Run `zig fmt` once, early, on the files you touch.** It is the only
   automatic upgrader: it rewrites `@intFromEnum`/`@enumFromInt` to
   `@backingInt`/`@fromBackingInt(@intCast(…))`. It **cannot parse** files that
   still contain `**` (array repeat) or `errdefer |err|`; fix those by hand
   first or fmt aborts on the whole file.
5. **Grep for the silent traps** in §4 by hand — the compiler will never
   point at them. The worst: `std.mem.containsAtLeastScalar` swapped its last
   two arguments; `@hasDecl` now ignores non-`pub` declarations; run-step path
   arguments became relative; `build()` results are cached.
6. **All in, one way (§0.1).** Target 0.17.0 only. No compatibility shims,
   no dual-version code, no deprecated spellings kept because they still
   compile. Comments and docs describe the code as it is, never its history.
7. **Done means:** `zig build` and `zig build test` pass, every published
   target/optimize mode builds, `zig fmt --check` passes on touched files, the
   §23 grep sweep is clean, and a representative workload in Debug is not
   dramatically slower than before.
8. **Leave what you learn here.** When a port teaches something this guide
   lacks (a trap, an error message, a std regression, a measurement), add
   it where the next reader will look for it: §4 for silent traps, §22 for
   error text, §24 for bugs, §23.6–§23.7 for speed. Verify it with a probe
   first, and give the numbers. Facts about one project stay in that
   project's own Zig notes, which link here instead of copying it.

**Copy-paste bootstrap prompt for a fresh agent session:**

```
You are migrating this repository to Zig 0.17.0 (or writing new 0.17 code).
Do not rely on your pretrained knowledge of Zig APIs.
1. Read ZIG-0.17.md §0–§4 and §25 before editing anything.
2. Run `zig version` (expect 0.17.0), then `zig build` and `zig build test`
   to get a baseline; do not edit yet.
3. Fix build.zig first, then sources, one API family at a time, compiling
   after each family.
4. When unsure of an API, read the 0.17 std source (`zig env` → std_dir) or
   compile a probe; never guess.
5. Go all in (§0.1): 0.17 only, no compatibility code, deprecated APIs
   migrated too; comments and docs say how things work, never what changed.
6. Run the §23 grep sweep and check every §4 trap by hand.
7. Finish only when build, tests, fmt --check and the sweep all pass, and a
   before/after benchmark shows no unexplained regression.
```

### 0.1 All in, one way, timeless

Migrations under this document follow one philosophy. Apply it to code,
comments, docs, build scripts and generated output alike.

**One version.** Code targets Zig 0.17.0 and nothing else. No dual-version
code paths, no `@hasDecl`/`builtin.zig_version` checks to keep an older Zig
working, no wrapper functions that recreate removed APIs, no "soft landing"
period. When a project generates code for other projects, the generated code
is 0.17 too, and its consumers move to 0.17 before they regenerate.

**Adopt the idiom, not the minimum.** "Still compiles" is not the bar.
Deprecated APIs are migrated in the same pass as removed ones:
`@backingInt`/`@fromBackingInt`, `gpa.print`, `std.mem.print`, `list.last()`,
`std.ArrayList`, `std.array_hash_map.*`, `std.bit_set.*`, `std.mem.find*`,
`std.lang`, `.debug/.safe/.fast/.small`, `builtin.target.*`,
`builtin.optimize.runtimeSafety()`, `SafeAllocator`, `BufferFirstAllocator`,
`@splat`, `@divCeil`. Use the new tools where they fit instead of keeping the
old workaround.

**Timeless text.** Comments, doc comments, READMEs, AGENTS files, error
messages and benchmark records describe how the code works *now*, in the
present tense, as if it had always been this way. History lives in git (and a
CHANGELOG if the project keeps one); plans live in the tracker.

| Never write | Write |
|---|---|
| `// Zig 0.17 removed **, so we use @splat here` | nothing, or what the code means: `// zero-filled lookup table` |
| `// was DebugAllocator` / `// formerly allocPrint` | nothing |
| `// TODO: switch to @backingInt once everyone is on 0.17` | the 0.17 code itself |
| "Nexus now needs Zig 0.17 (previously 0.16)." | "Nexus needs Zig 0.17." |
| "We used to build lists with a struct literal; this no longer works." | "`extendList` reuses the spare capacity of a kept list." |
| "Legacy notes for 0.16 are kept in `docs/zig-0.16/`." | delete the old notes; link the current reference |

Words that signal a violation: *now, no longer, used to, previously,
formerly, legacy, old, new (as in "the new API"), still, will, for now,
until, migrated, since 0.17*. This guide itself is the one exception: its job
is to map old spellings to new ones.

**Delete, don't deprecate.** Remove superseded docs, helpers and dead
compatibility branches outright. Git remembers them. Tooling counts too:
test-harness, differential and benchmark options that exist only to run an
old Zig or an old release of the project go (they usually cannot build on
0.17 anyway); a tool that compares against an old binary takes its path as
an argument instead.

**Optimize brutally, measure honestly.** Record a benchmark baseline *before*
the first edit, re-run it after, on the same machine and inputs, and quantify
run-to-run noise (run each side at least twice, interleave A/B runs).
Numbers in docs are current measurements, stated plainly; a regression is
reported with its cause, not hidden (§23.6, §23.7).

---

## 1. Version timeline and toolchain facts

| Version | Date | Headline changes an agent must know |
|---|---|---|
| 0.15.1/0.15.2 | Aug–Oct 2025 | `usingnamespace` and `async`/`await` removed; "Writergate": non-generic `std.Io.Writer`/`std.Io.Reader` with the buffer in the interface; `{f}` required for `format` methods; `ArrayList` became unmanaged; `BoundedArray`, `LinearFifo`, `RingBuffer` removed; self-hosted x86_64 backend is the Debug default on x86_64-linux. |
| 0.16.0 | 2026-04-16 | **I/O as an interface** (`std.Io` parameter everywhere: files, net, processes, time, sync, entropy); **Juicy Main** (`pub fn main(init: std.process.Init)`); `std.fs.*` → `std.Io.Dir`/`std.Io.File`; `std.net` → `std.Io.net`; sync primitives move from `std.Thread` to `std.Io`; `@Type` replaced by `@Int`/`@Struct`/`@Union`/`@Enum`/`@Pointer`/`@Fn`/`@Tuple`/`@EnumLiteral`; `@cImport` deprecated; container `.empty` decl literals; packed-type rules tightened; `zig-pkg/` package dir. |
| 0.17.0 | 2026-10-02 | Build system split into a **configurer** and a **maker** (`b.args` gone, `build()` cached, custom steps gone, many `*Build` fields gone); **reflection is struct-of-arrays** (`fields` → `field_names`/`field_types`/`field_attrs`); `std.builtin` → `std.lang`; optimize modes lowercase (`.debug/.safe/.fast/.small`); `**` array repetition removed (use `@splat`); `errdefer |err|` removed; `@cImport` removed; `@backingInt`/`@fromBackingInt`/`@divCeil` added; `@bitCast` redefined on logical bits; `SafeAllocator` replaces `DebugAllocator`; `Allocator.print` replaces `fmt.allocPrint`; `std.zon.parse` reworked. Everyday `std.Io` code from 0.16 compiles **unchanged**. |

0.17.0 toolchain: LLVM/Clang **22.1.8** (`zig cc`), musl 1.2.5, glibc 2.44
(cross), Linux 7.2 headers, macOS 27.0 headers, NetBSD 11.0 and OpenBSD 7.9
libc. LLVM loop vectorization is still **disabled** (an LLVM miscompile
workaround, to be lifted in 0.18 with LLVM 23): do not rely on
auto-vectorization; explicit `@Vector` code is unaffected.

Minimum OS versions for programs built with 0.17 std: **macOS 15.0+**
(raised from 13.0 in 0.16), Linux 5.10+, Windows 10+, FreeBSD 14.0+, NetBSD
10.1+, OpenBSD 7.8+, DragonFly 6.4+.

Debug-mode backends: self-hosted x86_64 backend is the Debug default on
x86_64-linux/-macos/-maccatalyst/-haiku/-serenity; everything else (including
**all aarch64**) uses LLVM. Override with `-fllvm` / `-fno-llvm`. The x86_64
backend rejects some inline-asm constraints LLVM accepts (e.g. `q`).

---

## 2. Reflexes that no longer compile (0.15 → 0.17)

The left column is what your training data will make you type. The middle
column is correct 0.17. "Since" is the release that broke the reflex.

### 2.1 Entry point, I/O, files, processes

| Your reflex | Correct in 0.17 | Since |
|---|---|---|
| `pub fn main() !void` + `std.process.argsAlloc(gpa)` | `pub fn main(init: std.process.Init) !void` then `try init.minimal.args.toSlice(init.arena.allocator())` | 0.16 |
| `std.heap.GeneralPurposeAllocator(.{}){}` | `init.gpa`, `init.arena.allocator()`, or `var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});` | 0.16/0.17 |
| `std.heap.DebugAllocator(.{})` (0.16's answer) | `std.heap.SafeAllocator` (DebugAllocator is deprecated) | 0.17 |
| `std.io.getStdOut().writer()` | `var buf: [4096]u8 = undefined; var fw = std.Io.File.stdout().writerStreaming(io, &buf); const w = &fw.interface;` … `try w.flush();` | 0.15/0.16 |
| `std.fs.cwd()` | `std.Io.Dir.cwd()` — and nearly every method takes `io` | 0.16 |
| `std.fs.File` / `std.fs.Dir` | `std.Io.File` / `std.Io.Dir` (`std.fs` keeps only `std.fs.path`) | 0.16 |
| `file.close()` | `file.close(io)` | 0.16 |
| `file.writeAll(bytes)` | `file.writeStreamingAll(io, bytes)` | 0.16 |
| `file.readToEndAlloc(gpa, max)` | `var fr = file.reader(io, &.{}); try fr.interface.allocRemaining(gpa, .limited(max))` | 0.16 |
| `dir.readFileAlloc(gpa, path, max)` | `dir.readFileAlloc(io, path, gpa, .limited(max))`; over the cap is `error.StreamTooLong` | 0.16 |
| `std.io.fixedBufferStream(buf)` | `std.Io.Writer.fixed(buf)` / `std.Io.Reader.fixed(bytes)` | 0.15/0.16 |
| `list.writer(gpa)` on `ArrayList(u8)` | `var out: std.Io.Writer.Allocating = .init(gpa);` then `out.writer.print(…)` (`writer` is a **field**) | 0.15/0.16 |
| `std.process.Child.init(argv, gpa)` / `.spawn()` | `var child = try std.process.spawn(io, .{ .argv = argv, … }); _ = try child.wait(io);` | 0.16 |
| `std.process.Child.run(…)` | `try std.process.run(gpa, io, .{ .argv = argv })` | 0.16 |
| `std.process.execv(arena, argv)` | `std.process.replace(io, .{ .argv = argv })` | 0.16 |
| `std.process.spawnPath(io, dir, …)` (0.16) | `std.process.spawn(io, .{ .exe = .{ .path = dir }, .argv = … })` | 0.17 |
| `std.os.environ`, `std.posix.getenv`, `std.process.getEnvVarOwned` | `init.environ_map.get("NAME")` (pass `*const std.process.Environ.Map` down) | 0.16 |
| `std.net.Stream` / `Server` / `Address` | `std.Io.net.Stream` / `Server` / `IpAddress` | 0.16 |
| `std.fs.selfExePathAlloc(gpa)` | `std.process.executablePathAlloc(io, gpa)` | 0.16 |
| `std.process.getCwdAlloc(gpa)` | `std.process.currentPathAlloc(io, gpa)` | 0.16 |
| `uri.getHost(&buf)` | `std.Io.net.HostName.fromUri(uri, &buf)` | 0.17 |

### 2.2 Time, threads, sync, entropy

| Your reflex | Correct in 0.17 | Since |
|---|---|---|
| `std.time.timestamp()` / `milliTimestamp()` / `nanoTimestamp()` | `std.Io.Clock.real.now(io).toSeconds()` / `.toMilliseconds()` / `.toNanoseconds()` | 0.16 |
| `std.time.Timer.start()` / `timer.read()`, `std.time.Instant` | `const t0 = std.Io.Clock.awake.now(io); … t0.untilNow(io, .awake).toNanoseconds()` | 0.16 |
| `std.Thread.sleep(ns)` / `std.time.sleep` | `try io.sleep(.fromMilliseconds(n), .awake)` | 0.16 |
| `std.Thread.Mutex` / `Condition` / `ResetEvent` / `Semaphore` / `RwLock` | `std.Io.Mutex` / `Condition` / `Event` / `Semaphore` / `RwLock`, all taking `io` | 0.16 |
| `std.Thread.WaitGroup` / `std.Thread.Pool` | `std.Io.Group` / `io.async` | 0.16 |
| `std.Thread.Futex.wait/wake` | free functions `std.Io.futexWait` / `futexWaitTimeout` / `futexWake` (no `Futex` type) | 0.16 |
| `std.crypto.random.bytes(&buf)` / `std.posix.getrandom` | `io.random(&buf)`; `try io.randomSecure(&buf)` for crypto | 0.16 |
| `std.once` | removed; avoid global state | 0.16 |

### 2.3 Language and builtins

| Your reflex | Correct in 0.17 | Since |
|---|---|---|
| `[_]u8{0} ** 16`, `"-" ** 40` | `const a: [16]u8 = @splat(0);` `const r: [40]u8 = @splat('-');` (pass `&r` where a slice is wanted) | 0.17 |
| `errdefer |err| log(err);` | catch at the call site: `inner() catch |err| { log(err); return err; };` | 0.17 |
| `@intFromEnum(e)` / `@enumFromInt(n)` | `@backingInt(e)` / `@fromBackingInt(n)` (old ones deprecated; `zig fmt` rewrites them) | 0.17 |
| `std.math.divCeil(T, a, b) catch unreachable` | `@divCeil(a, b)` | 0.17 |
| `@Type(.{ .int = … })` | `@Int(.unsigned, 10)`; also `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple`, `@EnumLiteral` | 0.16 |
| `std.meta.Int(…)` / `std.meta.Tuple(…)` | `@Int(…)` / `@Tuple(…)` (the `std.meta` versions are **removed**) | 0.17 |
| `inline for (@typeInfo(T).@"struct".fields) |f| f.name` | `const i = @typeInfo(T).@"struct"; inline for (i.field_names, i.field_types, i.field_attrs) |name, FT, attrs| …` | 0.17 |
| `std.meta.fields(T)` | `@typeInfo(T).@"struct".field_names` etc. (`std.meta.fields` is a `@compileError`) | 0.17 |
| `std.builtin.Type` / `std.builtin.Endian` / … | `std.lang.Type` / `std.lang.Endian` (`std.builtin` is a deprecated alias) | 0.17 |
| `builtin.mode == .Debug` | `builtin.optimize == .debug` (tags `.debug .safe .fast .small`) | 0.17 |
| `builtin.os.tag` / `builtin.cpu.arch` | `builtin.target.os.tag` / `builtin.target.cpu.arch` (old ones deprecated) | 0.17 |
| `@cImport({ @cInclude("x.h"); })` | translate the header in `build.zig` and `@import` the module (§20.6) | 0.17 (removed) |
| `@intFromFloat(f)` | `@trunc(f)` / `@floor` / `@ceil` / `@round` with an integer result type (old one deprecated) | 0.16 |
| `void{}` | `{}` | 0.17 |
| `i0` | `u0` | 0.17 |
| `/// doc` before `test "…"` | `// comment` | 0.16 |
| `packed struct { p: *T }` | store `usize`, convert with `@ptrFromInt`/`@intFromPtr` | 0.16 |
| `return &local;` | return by value or allocate | 0.16 |
| `vec[runtime_i]` | coerce to an array first: `const a: [N]T = vec;` | 0.16 |
| `usingnamespace`, `async`, `await` | removed (mixins via zero-bit fields + `@fieldParentPtr`) | 0.15 |

### 2.4 Containers, memory, formatting

| Your reflex | Correct in 0.17 | Since |
|---|---|---|
| `std.ArrayList(T).init(gpa)` | `var l: std.ArrayList(T) = .empty;` and pass `gpa` to every allocating call and to `deinit` | 0.15 |
| `var l: std.ArrayListUnmanaged(T) = .{};` | `= .empty` (no field defaults; struct literal also needs the new `pointer_stability` field) | 0.16/0.17 |
| `list.getLast()` / `getLastOrNull()` | `list.last().?` / `list.last()` | 0.17 |
| `std.AutoArrayHashMap(K, V).init(gpa)` | `var m: std.array_hash_map.Auto(K, V) = .empty;` + `gpa` per call | 0.16 |
| `std.fmt.allocPrint(gpa, fmt, args)` | `try gpa.print(fmt, args)` (old one deprecated) | 0.17 |
| `std.fmt.bufPrint(&buf, fmt, args)` | `try std.mem.print(&buf, fmt, args)` (old one deprecated) | 0.17 |
| `std.fmt.bufPrintZ(&buf, …)` | `try std.mem.printSentinel(&buf, fmt, args, 0)` (bufPrintZ **removed**) | 0.17 |
| `gpa.dupeZ(u8, s)` | `try gpa.dupeSentinel(u8, s, 0)` (dupeZ **removed**) | 0.17 |
| `std.heap.stackFallback(N, gpa)` | `var bfa: std.heap.BufferFirstAllocator = .init(&buf, gpa); const a = bfa.allocator();` | 0.17 |
| `std.fmt.format(writer, …)` | `writer.print(…)` | 0.15 |
| `pub fn format(self, comptime f, opts, writer)` | `pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void`, printed with `{f}` | 0.15 |
| `std.mem.trimLeft` / `trimRight` | `std.mem.trimStart` / `trimEnd` | 0.16 |
| `std.mem.indexOf*` | `std.mem.find*` (`indexOf*` are deprecated aliases) | 0.16 |
| `bitset.initEmpty()` / `initFull()` (static sets, `EnumSet`) | `.empty` / `.full` | 0.17 (removed) |
| `std.StaticBitSet(n)` / `std.DynamicBitSetUnmanaged` | `std.bit_set.Static(n)` / `std.bit_set.Dynamic` (old names deprecated) | 0.17 |
| `std.BoundedArray(T, n)` | `var buf: [n]T = undefined; var l: std.ArrayList(T) = .initBuffer(&buf);` + `*Bounded`/`*AssumeCapacity` | 0.15 |

### 2.5 Build system

| Your reflex | Correct in 0.17 | Since |
|---|---|---|
| `if (b.args) |args| run.addArgs(args);` | `run.addPassthruArgs();` | 0.17 |
| `.root_source_file` on `addExecutable` | `.root_module = b.createModule(.{ .root_source_file = …, .target, .optimize })` | 0.15 |
| `optimize == .Debug` / `.ReleaseFast` | `optimize == .debug` / `.fast` | 0.17 |
| `b.build_root.path` / `b.pathFromRoot("x")` | `b.root` (a `Cache.Path`; `b.fmt("{f}", .{b.root})` for a string) / `b.path("x")` | 0.17 |
| `b.install_path`, `b.getInstallPath(…)`, `b.cache_root` | lazy: `b.graph.path(.install_prefix, "sub")`, `std.Build.LazyPath.cache_root` | 0.17 |
| `lazy_path.getPath(b)` | removed — paths exist only at make time; pass the `LazyPath` to a step | 0.17 |
| custom step with `makeFn` | write a small Zig tool, `b.addExecutable` + `b.addRunArtifact` it | 0.17 |
| `b.addFmt(.{ .paths = &.{"src"} })` | `.paths = b.pathList(&.{"src"})` | 0.17 |
| `b.lazyDependency(…)` | `try b.dependencyLazy(…)` in `pub fn build(b: *std.Build) !void` | 0.17 |
| `@cImport` / `b.addTranslateC` | `translate_c` package `Translator` (or `b.addTranslateC`, deprecated) | 0.17 |
| `.name = "pkg"` in `build.zig.zon` | `.name = .pkg` + required `.fingerprint` | 0.16 |
| `zig build --global-cache-dir X` / `--zig-lib-dir X` | `ZIG_GLOBAL_CACHE_DIR=X zig build` / `zig build --zig-lib=X` (must be first arg) | 0.17 |

---

## 3. 0.16 → 0.17 at a glance

Ordered roughly by how often each hits a real codebase. **Fails** = compile
error (easy: the compiler finds them). **Deprecated** = still compiles, migrate
anyway. **Silent** = compiles and behaves differently (search by hand).

| # | Change | Old code | Fix |
|---|---|---|---|
| 1 | `b.args` removed | fails | `run_cmd.addPassthruArgs()` |
| 2 | Optimize modes lowercase: `std.lang.Optimize{ debug, safe, fast, small }` | `==`/`!=`/`orelse` with `.Debug` etc. **fails**; `switch` prongs and `const m: OptimizeMode = .ReleaseFast` still compile | `.debug .safe .fast .small`; read via `builtin.optimize` |
| 3 | `@intFromEnum`/`@enumFromInt` → `@backingInt`/`@fromBackingInt` | deprecated | `zig fmt` rewrites automatically |
| 4 | `x ** n` array repetition removed | fails (and breaks `zig fmt`) | `@splat` with a typed result |
| 5 | `std.fmt.allocPrint` → `Allocator.print`; `fmt.bufPrint` → `std.mem.print` | deprecated | `gpa.print(…)`, `std.mem.print(&buf, …)` |
| 6 | `@typeInfo` struct-of-arrays | fails | §6 |
| 7 | `std.builtin` → `std.lang`; `builtin.cpu/os/abi/object_format` → `builtin.target.*` | deprecated | rename |
| 8 | `errdefer |err|` removed | fails (and breaks `zig fmt`) | catch at the call site |
| 9 | `@cImport` removed; `b.addTranslateC` deprecated | fails | §20.6 |
| 10 | `DebugAllocator` → `SafeAllocator`; `deinit()` returns a leak count | deprecated; `deinit() == .leak` fails | §14 |
| 11 | `ArrayList.getLast/getLastOrNull` → `last()`; `lastPtr()` new | deprecated | `last().?` |
| 12 | `b.build_root`, `b.install_path`, `b.cache_root`, `getInstallPath`, `pathFromRoot`, `LazyPath.getPath*`, custom `makeFn` steps | fails | §20 |
| 13 | `addFmt .paths` are `LazyPath` lists | fails | `b.pathList(&.{…})` |
| 14 | `bit_set` renames; `initEmpty()`/`initFull()` removed | names deprecated; `initEmpty` fails | `.empty`/`.full` |
| 15 | `std.zon.parse` reworked (args struct, arena results) | fails | §17 |
| 16 | `stackFallback` → `BufferFirstAllocator` | fails | §14 |
| 17 | `std.meta.fields/declarationInfo/Int/Tuple` removed; `fieldNames` returns a slice | fails | §6 |
| 18 | `@bitCast` on `extern struct`/`extern union` rejected | fails | `@ptrCast`, `std.mem.bytesToValue`, or an `extern union` |
| 19 | Custom `pub const panic = struct {…}` needs `unexpectedErrorCode` and `loadUninstantiableType` | fails | §19.2 |
| 20 | `std.mem.containsAtLeastScalar(T, s, min, elem)` → `(T, s, elem, min)` | **silent** | swap the arguments |
| 21 | `@hasDecl` true only for `pub` decls, even in the same file | **silent** | make the decl `pub` or stop relying on it |
| 22 | `build()` output is cached; Run-step path args are relative | **silent** | §20.4 |
| 23 | `init.gpa`/`std.testing.allocator` are `SafeAllocator` | silent (new leak output format) | nothing, usually |
| 24 | `Uri.getHost` → `HostName.fromUri`; `process.spawnPath/replacePath` → `.exe` option; `File.OpenFlags/CreateFlags` removed | fails | §10–12 |
| 25 | `void{}`, `i0`, `.internal`/`.link_once` linkage removed | fails | `{}`, `u0`, don't export / `.weak` |

Everything else in everyday 0.16 `std.Io` code — Juicy Main, files, stdout,
child processes, clocks, mutexes, async/Group, TCP, `http.Client.fetch` —
**compiles unchanged** on 0.17 (verified by compiling the same programs with
both compilers).

---

## 4. Traps that compile (silent behaviour changes)

The compiler will not find any of these. Grep for them.

### 4.1 Introduced in 0.17

1. **`std.mem.containsAtLeastScalar` swapped its last two arguments.** 0.16:
   `(T, haystack, minimum, element)`; 0.17: `(T, haystack, element,
   minimum)`. Both are integers, so old calls compile and answer a different
   question: `containsAtLeastScalar(u8, "aab", 2, 'a')` is `true` on 0.16 and
   `false` on 0.17. Check every call by hand. (`containsAtLeastScalar2`, which
   had the new order in 0.16, is removed.)
2. **`@hasDecl(T, "name")` is `true` only for `pub` declarations**, even when
   called from the same file as `T`. 0.16 also saw private decls in the same
   file. Comptime feature detection on private decls silently flips to the
   "absent" branch.
3. **`build()` is cached.** The configure phase re-runs only when `build.zig`
   *content* or `-D` options change. It does **not** re-run when an
   environment variable read via `b.graph.environ_map` changes, when `b.run(…)`
   output would differ, or on `touch build.zig`. `std.debug.print` inside
   `build()` prints only on a cache miss. Declare inputs with
   `b.dependOnFileContents`/`dependOnFileMetadata`/`dependOnDirectoryContents`/
   `dependOnDirectoryMetadata`, or call `b.graph.poisonCache()`, or pass
   `--cache-poison=poisoned`. A documented `FOO=1 zig build test` breaks
   twice over: `build()` keeps the value it saw first, and test Run steps
   replay their cached results. Make it an option (`zig build test
   -Dfoo`) and set the variable on each Run step with
   `run.setEnvironmentVariable`, which puts it in the step's cache key.
   Without `clearEnvironment()` that call copies the whole configure-time
   environment into the cached configuration, so call it only when the
   option is set.
4. **Run-step path arguments and `addOptionPath` values are now relative**
   (`./build.zig`, `./zig-out`) where 0.16 passed absolute paths. Tools that
   `chdir` or resolve against another base break. Use the `…Arg2` variants with
   `.make_absolute = true`. The path is relative to the step's own cwd: a
   run with `setCwd` on a cache directory gets `../../../examples/x.nx`, and
   anything that prints the path prints that.
5. **Optimize-mode names print differently.** `@tagName(builtin.mode)` and
   `{t}` give `"debug"`/`"safe"`/`"fast"`/`"small"` instead of
   `"Debug"`/`"ReleaseSafe"`/…; anything that parses or compares those strings
   breaks.
6. **`init.gpa` is `SafeAllocator`** in Debug and ReleaseSafe (0.16:
   `DebugAllocator` in Debug, `c_allocator` in ReleaseSafe with libc).
   `std.testing.allocator` is also SafeAllocator-backed. Leak reports have a
   new format (log scope `.SafeAllocator`), memory is never reused, and every
   allocation carries a footer. Leaks still do not change the exit code.
7. **`Reader.allocRemaining(gpa, .limited(n))` now accepts exactly `n`
   bytes** (0.16 returned `error.StreamTooLong`). `Dir.readFileAlloc(…,
   .limited(n))` still rejects a file of exactly `n` bytes. Size your limits
   as "max + 1" if you need identical behaviour across both.
8. **`@bitCast` of arrays/vectors is defined on logical bits, element 0 least
   significant.** On little-endian targets results are unchanged for
   padding-free element types; on **big-endian** targets they flip
   (`[4]u8{0x10,0x20,0x30,0x40}` → `u32` was `0x10203040`, is now
   `0x40302010`). Padded element types now use packed sizes (`[8]bool` is 8
   bits, `[2]u4` is 8 bits), so some casts newly compile and others newly fail.
9. **`ArrayList(T)` grew from 24 to 32 bytes** in Debug/ReleaseSafe (the new
   `pointer_stability` field; still 24 in ReleaseFast/Small). Matters for
   `extern`/ABI assumptions, `@sizeOf` assertions, and copied lists (which copy
   their lock state).
10. **ZON serialization writes raw UTF-8** (`"hé"`) where 0.16 wrote
    `"h\xc3\xa9"`. Pass `.escape_non_ascii = true` to restore escaping.
11. **`{any}` of an unnamed non-exhaustive enum value prints
    `@fromBackingInt(7)`** instead of `@enumFromInt(7)`.
12. **`bit_set.Dynamic.setAll()` no longer sets padding bits** (`count()` of a
    70-bit set after `setAll` was 128, is now 70).
13. **`std.mem.eql` / `findDiff` on float slices** no longer short-circuit on
    identical pointers: a slice containing NaN is not equal to itself.
14. **`std.fmt.hex(x)` output length is `@bitSizeOf/4`** (was
    `2 * @sizeOf`), integers only.
15. **Networking:** `Socket.send` returns `error.MessageOversize` on a partial
    send; `sendMany` reports success on a partial batch with no OS error;
    `ip6_only` defaults to `null` (OS default) instead of `false`;
    `Uri.parse` splits userinfo on the **last** `@`; `HostName.max_len` is 254.
16. **`@typeInfo(enum {}).@"enum".tag_type` is `noreturn`**, not `u0`.
17. **`zig build test` replays cached test results.** When nothing the tests
    depend on changed, the run step prints `run test cached`, the summary
    shows no "tests passed" count, and no test runs. A gate re-run on an
    unchanged tree proves nothing: pass a fresh `--cache-dir` (or delete
    `.zig-cache`) when the point is to run the tests again. There is no
    flag that forces only the test runs; `--summary new` just hides cached
    steps.
18. **`@intCast` from a signed integer to a narrower unsigned one is LLVM
    `trunc nsw`,** so in ReleaseSafe and ReleaseFast any value at or above
    the target's sign bit is poison. `nsw` promises the value fits the
    narrow *signed* type; for `u8` that is -128..127, so 200 breaks it.
    After `if (r < 0 or r > 255) return false;`,
    `@as(u8, @intCast(r)) >= 128` (r an `i64`) folds to `false`; Debug
    gives `true`. Safe mode's range check passes and does not help. The
    cause is upstream commit `fa3a9fcdfa` ("llvm: only load/store
    ABI-sized integers to/from memory"), which made `Builder.convTag`
    narrow as `trunc nuw`/`trunc nsw` by the signedness it is given, and
    `airIntCast` passes the *operand's*; still so on master
    (0.17.0-432). `@truncate` stays a plain `trunc`, and widening and
    signed-to-signed casts are right. Cast through the unsigned type of the
    source's width, `@as(u8, @intCast(@as(u64, @intCast(r))))`: a negative
    value still fails the first cast, with the same panic, and the
    narrowing is `trunc nuw`. Or, where the range is already checked,
    `@truncate(@as(u64, @bitCast(r)))`. Watch for it in shift amounts
    (`x >> @intCast(n)`, `n` signed) and `@fromBackingInt(@intCast(n))`,
    the form `zig fmt` rewrites `@enumFromInt(n)` to. Check a build with
    `--verbose-llvm-ir` for `trunc nsw` to an unsigned type. Reproducer,
    to file upstream:

    ```zig
    const std = @import("std");
    noinline fn big(r: i64) bool {
        if (r < 0 or r > 255) return false;
        const b: u8 = @intCast(r);
        return b >= 128;
    }
    pub fn main() void {
        // Debug: true false. ReleaseSafe, ReleaseFast: false false.
        std.debug.print("{} {}\n", .{ big(200), big(100) });
    }
    ```

### 4.2 Carried over from 0.16 (still true in 0.17)

1. **`std.Io.Threaded.global_single_threaded.io()` has a failing allocator**
   (`Allocator.failing`). Use it only for leaf operations: clocks, sleep,
   futex, `io.random`, plain file reads/writes/stat. Anything that allocates
   through the `Io` — `std.process.spawn`/`run`/`replace`, networking, DNS —
   fails with `error.OutOfMemory` even with plenty of memory. Thread a real
   `init.io` to such code.
2. **Allocation-heavy code is very slow under the safety allocator in Debug.**
   0.16's `DebugAllocator` was measured up to 1,400× slower than an arena on
   workloads that keep many live allocations. 0.17's `SafeAllocator` is a
   different design (benchmarked ~25% faster and half the RSS on std's own
   tests) but still tracks every allocation and never reuses memory. For
   short-lived CLIs use `init.arena.allocator()`; time a real workload in
   Debug before declaring a migration done.
3. **`Writer.Allocating.written()` returns a borrowed slice that dies at the
   next write.** Copy it or call `toOwnedSlice()` first.
4. **A bare `{}` on a struct that has a `format` method does not call it** —
   it prints the fields (`.{ .x = 1 }`). Only `{f}` calls `format`. (`{}` on
   a string or optional *is* a compile error; on a struct it is not.)
5. **`{s:10}` right-aligns** a string by default (`"        hi"`); use
   `{s:<10}` for left alignment.
6. **`std.debug.print` bypasses your `Io`** and writes straight to stderr. Use
   it for diagnostics, never for program output.
7. **Copying an `std.Io.File.Writer` or `File.Reader` breaks it.** The vtable
   recovers the outer struct from the address of `.interface`. Always take
   `&fw.interface`, never `fw.interface` by value.
8. **Nothing is written until `flush()`.** Buffered writers hold output; a
   `std.process.exit` skips your `defer`s, so flush first.
9. **`std.Io.Group` is not a counting latch.** It is a task orchestrator tied
   to async/cancelation. For a plain counter use `std.Io.Semaphore` or an
   atomic plus `std.Io.Event`.
10. **The native stack is not checked.** Recursion on user-controlled depth
    segfaults. Guard it yourself or run on a thread with a large stack
    (`std.Thread.spawn(.{ .stack_size = 1 << 30 }, …)`).

---

## 5. Language

### 5.1 Removed syntax (0.17)

```zig
// Array repetition `**` is gone; `++` (concatenation) and `**T` (pointer to pointer) are unchanged.
const zeros: [16]u8 = @splat(0);                 // was [_]u8{0} ** 16
const grid: [2][4]u8 = @splat(@splat(1));        // was [_][4]u8{[_]u8{1} ** 4} ** 2
const rule: [40]u8 = @splat('-');                // was "-" ** 40 — pass `&rule` where []const u8 is wanted
try w.writeAll(&@as([8]u8, @splat(' ')));        // no result type? give one with @as
```

`"ab" ** 3` (a multi-byte pattern) has no one-line replacement; use a comptime
helper:

```zig
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return comptime blk: {
        @setEvalBranchQuota(2 * n + 1000); // the default quota stops the loop past n = 1000
        var buf: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        const final = buf;
        break :blk &final;
    };
}
```

The error for leftover `**` is misleading: `error: binary operator '*' has
whitespace on one side, but not the other` (spaced form) or `error: expected
type 'type', found 'comptime_int'` (unspaced `x**16`). **`zig fmt` refuses to
format the file** while any `**` repetition remains, so its 0.17 upgrades
(`@intFromEnum` → `@backingInt` and the rest) skip that file without a word:
remove every `**` first, then run `zig fmt` again.

```zig
// errdefer capture is gone. Plain `errdefer` still works.
fn process(job: Job) !void {
    processInner(job) catch |err| {
        std.log.err("job failed: {t}", .{err});
        return err;
    };
}
fn processInner(job: Job) !void { … }
```

Old form error: `error: expected block or expression, found '|'` (also aborts
`zig fmt`).

Also removed: `void{}` (write `{}`; error *type 'void' does not support array
initialization syntax*; `zig fmt` does not catch it), the `i0` type (use `u0`),
the `.internal` and `.link_once` global linkages (`std.lang.GlobalLinkage` is
now `enum(u1) { strong, weak }`), the number literal `1e1.5`, and duplicate
pointer qualifiers (`*const const T`: *Extra pointer qualifier*; `zig fmt`
silently drops the duplicate).

### 5.2 New builtins (0.17)

```zig
const Color = enum(u8) { red = 1, green = 2, blue = 4 };
const Flags = packed struct(u8) { lo: u4, hi: u4 };

const n: u8 = @backingInt(Color.blue);                 // 4      (was @intFromEnum)
const c: Color = @fromBackingInt(2);                   // .green (was @enumFromInt)
const f: Flags = @fromBackingInt(@as(u8, 0x5C));       // packed struct with EXPLICIT backing int
const raw: u8 = @backingInt(f);                        // 0x5C
const tag_int = @backingInt(tagged_union_value);       // the active tag's integer
const B = std.meta.BackingInt(Color);                  // u8
const q = @divCeil(7, 2);                              // 4; @divCeil(-5, 3) == -1; works on floats and vectors
```

Rules:

- `@fromBackingInt` infers its result type and requires an argument of
  **exactly** the backing integer type. A comptime-known literal is fine
  (range-checked at compile time). A runtime integer of another type needs
  `@intCast`: `const e: Color = @fromBackingInt(@intCast(n_usize));`.
- `@backingInt`/`@fromBackingInt` on a `packed struct` require an explicit
  backing integer (`packed struct(u8)`); with an inferred one, keep using
  `@bitCast` (*@backingInt is ambiguous for type 'PS'*).
- An invalid tag passed to `@fromBackingInt` is safety-checked illegal
  behaviour (compile error at comptime: *enum 'E' has no tag with value '5'*).
- `@intFromEnum`/`@enumFromInt` still compile, without warnings, and
  `@enumFromInt` still accepts any integer type. `zig fmt` 0.17 rewrites them
  to `@backingInt(x)` and `@fromBackingInt(@intCast(x))` — it always inserts
  the `@intCast`, even around literals. That is harmless.
- `@fromBackingInt(x)` takes exactly the backing type. A hand rename (or an
  emitter rewrite) of `@enumFromInt(x)` to `@fromBackingInt(x)` fails when
  `x` is any other integer type (*expected type 'u32', found 'i64'*); keep the
  `@intCast`. An invalid tag still panics (*invalid enum value*).
- `@bitCast` to an enum is now **allowed** and safety-checked (0.16 rejected
  it).
- Empty enums: `enum {}` now has tag type `noreturn`; `enum(u8) {}` is an
  error (*empty exhaustive enums must be backed by 'noreturn'*).
- `@SpirvType(options)` creates SPIR-V images, samplers, sampled images and
  runtime arrays (SPIR-V targets only).

Comptime-length slices now dereference and coerce to array pointers:

```zig
const slice: []const u16 = &.{ 1, 2, 3 };
const array: [3]u16 = slice.*;
const ptr: *const [3]u16 = slice;
```

### 5.3 `@bitCast` (redefined in 0.17)

`@bitCast` reinterprets the **logical** bit representation. Types that have
one: `void`, `bool`, integers, floats (not `comptime_*`), `enum(T)`,
`packed struct(T)`, `packed union(T)`, and arrays/vectors of these. Arrays and
vectors concatenate element bit patterns with element 0 least significant. The
operation is endian-independent.

**No longer allowed:** `@bitCast` from or to `extern struct`/`extern union`
(*cannot @bitCast from 'X.TwoBytes'*). For in-memory type punning use
`@ptrCast`, `std.mem.bytesToValue`, or an `extern union`:

```zig
const TwoBytes = extern struct { b0: u8, b1: u8 };
const bytes: TwoBytes = .{ .b0 = 0x12, .b1 = 0xAB };
const int_ptr: *align(1) const u16 = @ptrCast(&bytes);       // native-endian view of memory
const back: TwoBytes = std.mem.bytesToValue(TwoBytes, std.mem.asBytes(&int_ptr.*));
const Pun = extern union { s: TwoBytes, i: u16 };
```

Integer↔integer and integer↔packed `@bitCast`s are unchanged. If code relied
on big-endian **memory order** of an array cast, use `@ptrCast` or
`std.mem.readInt(T, &bytes, .big)` instead.

**In a hot path, load words with `std.mem.readInt`, not an array
`@bitCast`.** Being logical, an array cast is lowered element by element:
`const w: [4]u64 = @bitCast([2][16]u8{ a[0..16].*, b[0..16].* })` made a
hash's 17–240-byte path 3–9× slower than four `readInt(u64, …, .little)`
calls (aarch64-macos, `-Ofast`). A 64-byte vector load is fastest through a
pointer: `@as(*align(1) const @Vector(8, u64), @ptrCast(p)).*`.

### 5.4 Optimize modes and `@import("builtin")` (0.17)

```zig
const builtin = @import("builtin");

if (builtin.optimize == .debug) {}                 // type std.lang.Optimize: .debug .safe .fast .small
if (builtin.optimize.runtimeSafety()) {}           // replaces std.debug.runtime_safety (deprecated)
const os = builtin.target.os.tag;                  // was builtin.os.tag
const arch = builtin.target.cpu.arch;              // was builtin.cpu.arch
const abi = builtin.target.abi;                    // was builtin.abi
const ofmt = builtin.target.ofmt;                  // was builtin.object_format
```

- `builtin.mode` still works (alias of `optimize`, removal after 0.18).
- `== .Debug`, `!= .ReleaseFast`, `orelse .ReleaseSafe` → *error: no field
  named 'Debug' in enum 'lang.Optimize'*. `switch` prongs naming
  `.Debug`/`.ReleaseFast` and `const m: std.builtin.OptimizeMode =
  .ReleaseFast` still compile through deprecated decls (removal after 0.18).
- `builtin.cpu/os/abi/object_format` are deprecated (doc-comment only, no
  warning), removed in 0.18. The `builtin.target.*` spellings also work on 0.16.
- `std.lang.Optimize.fromString("ReleaseSmall")` accepts old and new names.
- CLI: `-O fast` / `-Doptimize=fast` (old names still accepted);
  `--release=` accepts only `off|any|fast|safe|small`.

### 5.5 `std.builtin` → `std.lang` (0.17)

`std.builtin` is now `pub const builtin = lang;` — a deprecated alias,
scheduled for removal. Write `std.lang.Type`, `std.lang.Endian`,
`std.lang.CallingConvention`, `std.lang.AddressSpace`, `std.lang.Optimize`,
`std.lang.GlobalLinkage`, `std.lang.StackTrace`, … Note that `std.lang` does
**not** exist in 0.16, so code that must build on both uses `std.builtin`.
`std.gpu` was renamed `std.spirv` with no alias.

### 5.6 Type-creating builtins (0.16; attribute type names changed in 0.17)

`@Type` is gone. One builtin per category:

```zig
@EnumLiteral() type
@Int(signedness, bits) type
@Tuple(field_types) type
@Pointer(size, attrs, Element, sentinel) type
@Fn(param_types, param_attrs, ReturnType, attrs) type
@Struct(layout, BackingInt, field_names, field_types, field_attrs) type
@Union(layout, TagType, field_names, field_types, field_attrs) type
@Enum(TagInt, mode, field_names, field_values) type
```

There is no `@Float`, `@Array`, `@Optional`, `@ErrorUnion`, `@Opaque` or
`@ErrorSet`: use syntax (`f32`, `[N]T`, `?T`, `E!T`, `opaque {}`) or
`std.meta.Float(bits)`. Error sets cannot be reified; tuple types with
`comptime` fields cannot be reified. Examples in §6.3.

### 5.7 Packed types, numerics, vectors, pointers (0.16)

- **Packed unions have no unused bits:** every field has the union's
  `@bitSizeOf`. `packed union { x: u8, y: u16 }` is an error; write
  `packed union(u16) { x: packed struct(u16) { data: u8, pad: u8 = 0 }, y: u16 }`.
- **No pointers in `packed struct`/`packed union`** (*packed structs cannot
  contain fields of type '*u8'*). Store a `usize`; convert with
  `@ptrFromInt`/`@intFromPtr`. Pointers are fine everywhere else.
- **Enums with an inferred tag and packed types with an inferred backing
  integer are not valid `extern` types.** Spell them out: `enum(u8)`,
  `packed struct(u32)`.
- Packed structs/unions compare with `==` and work as `switch` prong items
  (by backing integer).
- **Small integers coerce to floats implicitly** when every value fits
  (`u24` → `f32`, `u53` → `f64`); otherwise `@floatFromInt`.
- **Float → int:** `@trunc`, `@floor`, `@ceil`, `@round` take an integer
  result type (`const n: i64 = @round(x);`). `@intFromFloat` is deprecated
  (≡ `@trunc`). Unary float builtins forward the result type:
  `const r: f64 = @sqrt(@floatFromInt(n));`.
- **Vectors cannot be indexed with a runtime index** (*vector index not
  comptime known*); coerce first: `const arr: [4]f32 = vec;`. `@ptrCast`
  between `*[4]T` and `*@Vector(4, T)` is not allowed; use value coercion.
- **Returning the address of a local is an error** (*returning address of
  expired local variable 'x'*).
- `*T` and `*align(1) T` (where `T`'s natural alignment ≠ 1) are distinct
  types that coerce freely.
- Pointers to comptime-only types (`[]const std.lang.Type…`) exist at runtime
  but can be dereferenced only for runtime-typed fields.

### 5.8 `switch`, type resolution, misc (0.16)

- Union tag captures are allowed on every prong; decl literals and anything
  needing a result type work as prong items; `switch` on `void` needs no
  `else`; prong captures may not all be discarded; error prongs outside the
  switched set are allowed when they resolve to `=> comptime unreachable`.
- **Lazy field analysis:** types used only as namespaces (including files)
  are not field-resolved; a non-dereferenced `*T` does not resolve `T`.
- **Dependency loops** report `dependency loop with length N` with numbered
  "uses X here" notes; read top to bottom and break one link. A struct whose
  field alignment uses `@alignOf(@This())` is such a loop.
- Zero-bit tuple fields are not implicitly `comptime`.
- **`///` doc comments before `test` blocks are an error** (*documentation
  comments cannot be attached to tests*). `//!` module docs are fine.
- Unused locals/params and never-mutated `var`s remain errors (`_ = x;`,
  `_ = &x;`).

### 5.9 From 0.15 (recap)

- `usingnamespace` is gone. Conditional inclusion: `pub const foo = if (have)
  123 else {};` or `@compileError`. Implementation selection: `pub const init =
  switch (os) { .windows => initWindows, else => initPosix };`. Mixins: a
  zero-bit field plus `@fieldParentPtr`:

  ```zig
  pub fn CounterMixin(comptime T: type) type {
      return struct {
          pub fn increment(m: *@This()) void {
              const x: *T = @alignCast(@fieldParentPtr("counter", m));
              x.count += 1;
          }
      };
  }
  const Foo = struct { count: u32 = 0, counter: CounterMixin(Foo) = .{} };
  // foo.counter.increment()
  ```
- `async`/`await` keywords and `@frameSize` are gone (concurrency is
  `io.async`, §13).
- Labeled `switch` with `continue :sw value` and `inline else => |x, tag|`
  prongs are idiomatic state-machine tools.
- Inline-asm clobbers are a struct: `: .{ .rcx = true, .r11 = true }`.
- Comptime arithmetic on `undefined` is an error; lossy int→float literal
  coercion at comptime is an error (`const f: f32 = 123_456_789;`).

---

## 6. Reflection: `@typeInfo`, `std.lang.Type`, type-creating builtins

### 6.1 The 0.17 shape (struct-of-arrays)

Every kind that used to carry a `fields`/`decls`/`params` array of structs
now carries parallel arrays. There is no auto-fix.

```zig
pub const Type = union(enum) {
    type, void, bool, noreturn, int: Int, float: Float, pointer: Pointer, array: Array,
    @"struct": Struct, comptime_float, comptime_int, undefined, null, optional: Optional,
    error_union: ErrorUnion, error_set: ErrorSet, @"enum": Enum, @"union": Union, @"fn": Fn,
    @"opaque": Opaque, frame: Frame, @"anyframe": AnyFrame, vector: Vector, enum_literal,
    spirv: Spirv, // new in 0.17

    pub const Struct = struct {
        is_tuple: bool,
        layout: ContainerLayout,                 // .auto, .@"extern", .@"packed"
        backing_integer: ?type,                  // non-null only for packed
        field_names: []const [:0]const u8,
        field_types: []const type,
        field_attrs: []const FieldAttributes,
        decl_names: []const [:0]const u8,        // pub decls only
        pub const FieldAttributes = struct {
            @"comptime": bool = false,
            @"align": ?usize = null,             // null = natural alignment
            default_value_ptr: ?*const anyopaque = null,
            pub inline fn defaultValue(comptime attrs: FieldAttributes, comptime FieldType: type) ?FieldType;
        };
    };
    pub const Enum = struct {
        tag_type: type,
        mode: Mode,                              // enum { exhaustive, nonexhaustive }
        field_names: []const [:0]const u8,
        field_values: []const comptime_int,
        decl_names: []const [:0]const u8,
    };
    pub const Union = struct {
        layout: ContainerLayout,
        tag_type: ?type,
        backing_integer: ?type,                  // new: packed unions only
        field_names: []const [:0]const u8,
        field_types: []const type,
        field_attrs: []const FieldAttributes,    // struct { @"align": ?usize = null }
        decl_names: []const [:0]const u8,
    };
    pub const ErrorSet = struct { error_names: ?[]const [:0]const u8 };   // null = anyerror
    pub const Fn = struct {
        attrs: Attributes,                       // struct { @"callconv": CallingConvention = .auto, varargs: bool = false }
        is_generic: bool,
        return_type: ?type,                      // null = generic
        param_types: []const ?type,              // null = anytype / generic param
        param_attrs: []const ParamAttributes,    // struct { @"noalias": bool = false }
    };
    pub const Pointer = struct {
        size: Size,                              // enum(u2) { one, many, slice, c }
        attrs: Attributes,                       // @"const", @"volatile", @"allowzero", @"addrspace": ?AddressSpace, @"align": ?usize
        child: type,
        sentinel_ptr: ?*const anyopaque,
        pub inline fn sentinel(comptime ptr: Pointer) ?ptr.child;
    };
    pub const Opaque = struct { decl_names: []const [:0]const u8 };
    // Int, Float, Array, Optional, ErrorUnion, Vector, Frame, AnyFrame: unchanged.
    // Removed: StructField, UnionField, EnumField, Error, Declaration, Fn.Param.
};
```

### 6.2 Mapping 0.16 → 0.17

| 0.16 | 0.17 |
|---|---|
| `s.fields[i].name` / `.type` | `s.field_names[i]` / `s.field_types[i]` |
| `s.fields[i].defaultValue()` / `.default_value_ptr` | `s.field_attrs[i].defaultValue(T)` / `s.field_attrs[i].default_value_ptr` |
| `s.fields[i].is_comptime` / `.alignment` | `s.field_attrs[i].@"comptime"` / `s.field_attrs[i].@"align"` (null = natural) |
| `s.decls[i].name` | `s.decl_names[i]` |
| enum `fields[i].value`, `is_exhaustive` | `field_values[i]`, `mode == .exhaustive` |
| `error_set.?[i].name` | `error_set.error_names.?[i]` |
| fn `params[i].type` / `.is_noalias` / `.is_generic` | `param_types[i]` / `param_attrs[i].@"noalias"` / `param_types[i] == null` |
| fn `calling_convention` / `is_var_args` | `attrs.@"callconv"` / `attrs.varargs` |
| pointer `is_const`/`is_volatile`/`is_allowzero`/`alignment`/`address_space` | `attrs.@"const"`/`.@"volatile"`/`.@"allowzero"`/`.@"align"`/`.@"addrspace".?` |
| `Type.StructField.Attributes` (0.16 builtin arg type) | `Type.Struct.FieldAttributes` |
| `Type.UnionField.Attributes` / `Type.Fn.Param.Attributes` | `Type.Union.FieldAttributes` / `Type.Fn.ParamAttributes` |

### 6.3 Patterns

```zig
const std = @import("std");

const Point = struct { x: i32 = 0, y: i32 = 0, pub const origin: Point = .{}; };
const Color = enum(u8) { red = 1, green = 2, blue = 4 };

test "reflection" {
    const s = @typeInfo(Point).@"struct";
    inline for (s.field_names, s.field_types, s.field_attrs) |name, T, attrs| {
        _ = name;
        try std.testing.expectEqual(@as(?T, 0), attrs.defaultValue(T));
        try std.testing.expect(!attrs.@"comptime");
    }
    try std.testing.expectEqualStrings("origin", s.decl_names[0]);

    const e = @typeInfo(Color).@"enum";
    inline for (e.field_names, e.field_values) |name, value| {
        try std.testing.expectEqual(@field(Color, name), @as(Color, @fromBackingInt(value)));
    }
    try std.testing.expect(e.mode == .exhaustive);

    // Reify: names/types/attrs are separate arrays. `&@splat(.{})` = default attributes.
    const S = @Struct(.auto, null, &.{ "a", "b" }, &.{ u32, bool }, &.{
        .{ .default_value_ptr = &@as(u32, 5) },
        .{ .@"align" = 8 },
    });
    const v: S = .{ .b = true };
    try std.testing.expectEqual(5, v.a);
    const P = @Struct(.@"packed", u8, &.{ "lo", "hi" }, &.{ u4, u4 }, &@splat(.{}));
    try std.testing.expectEqual(8, @bitSizeOf(P));
    const Tag = @Enum(u8, .exhaustive, &.{ "i", "f" }, &.{ 0, 1 });
    const U = @Union(.auto, Tag, &.{ "i", "f" }, &.{ u32, f32 }, &@splat(.{}));
    _ = U;
    const F = @Fn(&.{ *u8, u32 }, &.{ .{ .@"noalias" = true }, .{} }, void, .{ .@"callconv" = .auto });
    _ = F;
    try std.testing.expect(@Pointer(.slice, .{ .@"const" = true }, u8, 0) == [:0]const u8);
    try std.testing.expect(@Int(.unsigned, 7) == u7);
    try std.testing.expect(@Tuple(&.{ u8, bool }) == struct { u8, bool });

    // Re-reifying an existing struct: slices must become array pointers.
    const n = s.field_names.len;
    const Copy = @Struct(s.layout, s.backing_integer, s.field_names, s.field_types[0..n], s.field_attrs[0..n]);
    _ = Copy;
}
```

### 6.4 `std.meta` (0.17)

| Helper | Status |
|---|---|
| `std.meta.fields(T)` | **`@compileError`** "deprecated in favor of @typeInfo" |
| `std.meta.declarationInfo` | **`@compileError`** "deprecated in favor of @hasDecl" |
| `std.meta.Int`, `std.meta.Tuple` | **removed** → `@Int`, `@Tuple` |
| `std.meta.fieldNames(T)` | deprecated; now returns a **slice** → `inline for (comptime std.meta.fieldNames(T))` |
| `std.meta.fieldTypes(T)` | deprecated; slice of types (compare with `comptime`) |
| `std.meta.fieldInfo(T, .f)` | deprecated; returns `{ name, type, attrs }` |
| `std.meta.declarations(T)` | returns `[]const [:0]const u8` (names), not `[]Declaration` |
| `std.meta.FieldEnum`, `stringToEnum`, `activeTag`, `Tag`, `Child`, `Elem`, `eql`, `hasFn`, `Float` | unchanged |
| `std.meta.BackingInt`, `BareUnion`, `Slice`, `AbsorbSentinel` | new |
| `std.enums.valuesFromFields(E, …)` | now takes `@typeInfo(E).@"enum".field_values` |

---

## 7. `std.Io`: I/O as an interface

**Anything that blocks or observes the outside world goes through a
`std.Io` value**: files and directories, networking, DNS, processes, clocks,
sleep, entropy, mutexes/conditions/events/semaphores/futexes, async tasks,
cancelation. Lock-free atomics do not need it. Pass `io: std.Io` the way you
pass `allocator: std.mem.Allocator`: the program picks the implementation
once, at the top.

| Context | Where the `Io` comes from |
|---|---|
| `pub fn main(init: std.process.Init)` | `init.io` (a `std.Io.Threaded`) |
| tests | `std.testing.io` |
| `build.zig` | `b.graph.io` |
| your own setup | `var threaded: std.Io.Threaded = .init(gpa, .{ .environ = minimal.environ }); defer threaded.deinit(); const io = threaded.io();` |
| leaf code with no `Io` to hand | `std.Io.Threaded.global_single_threaded.io()` — **leaf syscalls only** (§4.2.1) |

Implementations: `Io.Threaded` (feature-complete, the default),
`Io.Evented` (experimental green threads; no networking), `Io.Uring`,
`Io.Kqueue`, `Io.Dispatch` (proofs of concept), `Io.failing` (every call
errors; for testing refusal paths). `Io.Threaded.InitOptions`:
`stack_size`, `async_limit`, `concurrent_limit`, `argv0`, `environ`,
`disable_memory_mapping`. `var t: Io.Threaded = .init_single_threaded;` gives a
local single-threaded instance (its allocator is `failing` too).

Library guidance: libraries take `io: Io` as a parameter. A library that
needs an `Io` only for a futex, a timestamp or entropy may use
`global_single_threaded` instead of polluting its API — std itself documents
that use. It is safe to call from many OS threads; it simply has no worker
pool, no concurrency and no cancelation.

`std.Io.VTable` is an implementation detail. 0.17 moved `netRead`,
`netWrite`, `netSend` into `Io.Operation` tags and removed
`processSpawnPath`/`processReplacePath`; code that called
`io.vtable.netRead(…)` directly must use the public stream/socket API.

---

## 8. `main`, arguments, environment

### 8.1 Three shapes of `main`

```zig
pub fn main() !void {}                                  // no args, no env, no io provided
pub fn main(init: std.process.Init.Minimal) !void {}    // raw argv + environ
pub fn main(init: std.process.Init) !void {}            // "Juicy Main": io, gpa, arena, env map, args
```

`std.process.Init` fields: `minimal: Init.Minimal` (`.args`, `.environ`),
`arena: *std.heap.ArenaAllocator` (process lifetime, threadsafe),
`gpa: std.mem.Allocator`, `io: std.Io`, `environ_map: *std.process.Environ.Map`,
`preopens` (WASI; `void` elsewhere).

`init.gpa` is `SafeAllocator` in Debug and ReleaseSafe (leak-checked at
exit), `c_allocator` when libc is linked in Fast/Small, else `smp_allocator`.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();               // short-lived CLI: allocate here, never free

    const args = try init.minimal.args.toSlice(arena);  // []const [:0]const u8; args[0] is the program
    const home = init.environ_map.get("HOME") orelse "(unset)";

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &stdout.interface;                        // take the ADDRESS, never copy `interface`
    try w.print("{d} argument(s); HOME={s}\n", .{ args.len - 1, home });
    try w.flush();
}
```

- Zero-allocation argument walk: `var it = init.minimal.args.iterate();
  _ = it.skip(); while (it.next()) |arg| …` (POSIX; `iterateAllocator` is the
  portable form).
- The environment is never global: no `std.os.environ`, no
  `std.posix.getenv`. Functions that need it take
  `*const std.process.Environ.Map`. `Environ.Map` has `get`, `put`, `putAll`,
  `remove`, `keys()`, `values()`, `clearRetainingCapacity`.
- With `Init.Minimal`: `init.environ.getPosix("HOME")`,
  `init.environ.getAlloc(arena, "X")`, `init.environ.contains(arena, "X")`,
  `try init.environ.createMap(arena)`.
- Returning an error from `main` logs `error: Name`, dumps the error return
  trace in Debug, and exits 1. `std.process.exit(code)` exits immediately
  without running `defer`s (flush first). `std.process.fatal(fmt, args)` logs
  and exits 1.

### 8.2 Choosing the allocator in `main`

| Program shape | Use |
|---|---|
| one-shot CLI: read input, compute, write, exit; code generators; compilers | `init.arena.allocator()` |
| long-running server, daemon, REPL, LSP | `init.gpa`, and fix every leak |
| library | take an `Allocator` parameter |
| leak hunting in a CLI | `init.gpa` behind a flag or env var |

---

## 9. Writers, readers, `Io.Limit`

`std.Io.Writer` and `std.Io.Reader` are the only stream interfaces (since
0.15). Each is a struct holding a **buffer** plus a vtable; nothing reaches
the sink until the buffer fills or you call `flush()`. Functions take
`w: *std.Io.Writer` / `r: *std.Io.Reader` (not `anytype`); the error set is
`std.Io.Writer.Error` (`error{WriteFailed}`) / `std.Io.Reader.Error`. The
concrete cause is kept on the implementation (`file_writer.err`).

### 9.1 stdout and stderr

```zig
var buf: [4096]u8 = undefined;
var fw = std.Io.File.stdout().writerStreaming(io, &buf);   // streaming: stdout, stderr, pipes
const out = &fw.interface;
try out.print("x = {d}\n", .{42});
try out.flush();

try std.Io.File.stdout().writeStreamingAll(io, "one unbuffered write\n");

// Shared stderr (serialised with std.debug.print):
var ebuf: [256]u8 = undefined;
const stderr = try io.lockStderr(&ebuf, null);
defer io.unlockStderr();
try stderr.file_writer.interface.print("warning: {s}\n", .{msg});
// Without an Io: const held = std.debug.lockStderr(&ebuf); defer std.debug.unlockStderr();
```

`file.writer(io, &buf)` starts in **positional** mode (`pwrite` at an offset,
falling back to streaming); `file.writerStreaming(io, &buf)` writes at the
current position. Use `writerStreaming` for stdio and pipes. `file.isTty(io)`
can fail with `error.Canceled`.

### 9.2 Building strings in memory: `Writer.Allocating`

```zig
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();                       // safe even after toOwnedSlice()
try emitHeader(&out.writer, "main");      // `writer` is a FIELD: &out.writer, out.writer.print(...)
try out.writer.writeAll("const x = 1;\n");
const view = out.written();               // borrowed; invalid after the next write
const owned = try out.toOwnedSlice();     // caller frees; `out` is empty again
```

Also: `initCapacity`, `initOwnedSlice`, `fromArrayList(gpa, &list)` /
`toArrayList()`, `toOwnedSliceSentinel(0)`, `ensureUnusedCapacity`,
`clearRetainingCapacity`, `shrinkRetainingCapacity`. For one-off strings use
`try gpa.print(fmt, args)`; to append formatted text to an `ArrayList(u8)` use
`try list.print(gpa, fmt, args)`.

### 9.3 Fixed buffers

```zig
var buf: [32]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try w.print("{d}-{d}", .{ 1, 2 });
const text = w.buffered();                // "1-2"; overflow is error.WriteFailed

var r: std.Io.Reader = .fixed("alpha\nbeta\n");
while (try r.takeDelimiter('\n')) |line| { _ = line; }   // null at end
```

`try std.mem.print(&buf, fmt, args)` formats straight into a slice
(`error.NoSpaceLeft` when full).

### 9.4 Reader calls you will use

| Call | Result |
|---|---|
| `r.takeDelimiter('\n')` | next line without the delimiter, `null` at end; `error.StreamTooLong` if a line exceeds the buffer |
| `r.takeByte()`, `r.peekByte()` | one byte; `error.EndOfStream` at end |
| `r.take(n)`, `r.takeArray(n)`, `r.peek(n)` | next `n` bytes borrowed from the buffer |
| `r.takeInt(u32, .little)`, `r.takeLeb128(T)` | binary decoding |
| `r.allocRemaining(gpa, .limited(n))` | everything left, owned (accepts exactly `n` bytes in 0.17) |
| `r.readAllocAll(gpa, n)` / `r.readAllocShort(gpa, n)` | exactly `n` bytes / up to `n` bytes (0.17; `readAlloc` is deprecated) |
| `r.streamRemaining(w)` | copy the rest to a writer |
| `r.discardAll(n)` | skip |

`File.Reader` adds `seekTo(n)`, `seekBy(d)`, `logicalPos()`; `File.Writer`
adds `seekTo` and `logicalPos` (the old `File.seekTo`/`getPos` live here now).

### 9.5 `std.Io.Limit`

APIs that read "up to some amount" take an `Io.Limit` (`enum(usize)`), not a
`usize`: `.limited(n)`, `.limited64(n)`, `.unlimited`, `.nothing`. Write
`std.Io.Limit.limited(n)` when the result type is not inferable. Exceeding a
limit is `error.StreamTooLong` (not `FileTooBig`). 0.17 adds
`limit.toInt64()`.

---

## 10. Files and directories

`std.fs` keeps only `std.fs.path`, itself deprecated in 0.17: write
`std.Io.Dir.path` (and `std.Io.Dir.max_path_bytes`).
Files and directories are `std.Io.File` and `std.Io.Dir`; nearly every method
takes `io` right after the receiver.

```zig
const std = @import("std");

test "files through Io.Dir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;                                    // a std.Io.Dir; std.Io.Dir.cwd() is the cwd

    try dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });

    const text = try dir.readFileAlloc(io, "a.txt", gpa, .limited(1 << 20));
    defer gpa.free(text);
    try std.testing.expectError(error.StreamTooLong, dir.readFileAlloc(io, "a.txt", gpa, .limited(6)));

    {
        const file = try dir.createFile(io, "b.txt", .{ .truncate = true });
        defer file.close(io);
        var buf: [256]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.print("{d}\n", .{123});
        try fw.interface.flush();                           // flush BEFORE close
    }
    {
        const file = try dir.openFile(io, "b.txt", .{});
        defer file.close(io);
        var buf: [256]u8 = undefined;
        var fr = file.reader(io, &buf);
        try std.testing.expectEqualStrings("123", (try fr.interface.takeDelimiter('\n')).?);
        const st = try file.stat(io);                       // .size, .kind, .mtime, .ctime, ?atime, .permissions
        try std.testing.expectEqual(4, st.size);
    }

    try dir.createDirPath(io, "x/y/z");
    try dir.access(io, "x/y/z", .{});
    try dir.rename("b.txt", dir, "c.txt", io);
    try dir.deleteFile(io, "a.txt");
    try std.testing.expectError(error.FileNotFound, dir.access(io, "a.txt", .{}));

    {
        var sub = try dir.openDir(io, "x", .{ .iterate = true });
        defer sub.close(io);
        var it = sub.iterate();
        while (try it.next(io)) |entry| _ = entry.name;
        var walker = try sub.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| _ = entry.path;
    }
    try dir.deleteTree(io, "x");
}
```

Atomic replace (temp file + rename; `O_TMPFILE` on Linux):

```zig
fn writeAtomically(io: std.Io, dir: std.Io.Dir, path: []const u8, contents: []const u8) !void {
    var af = try dir.createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, contents);   // or a buffered af.file.writer(io, &buf) + flush
    try af.replace(io);                            // with .replace = false, call af.link(io)
}
```

### 10.1 Renamed `std.fs` / `File` / `Dir` APIs (0.16)

| 0.15 | 0.17 |
|---|---|
| `std.fs.cwd()` | `std.Io.Dir.cwd()` |
| `std.fs.openFileAbsolute` (and `…DirAbsolute`, `createFileAbsolute`, `deleteFileAbsolute`, `renameAbsolute`, `makeDirAbsolute` …) | `std.Io.Dir.openFileAbsolute(io, …)` etc.; `makeDirAbsolute` → `createDirAbsolute` |
| `dir.makeDir` / `makePath` / `makeOpenPath` | `dir.createDir(io, p, perms)` / `createDirPath(io, p)` / `createDirPathOpen(io, p, .{})` |
| `std.fs.realpathAlloc`, `dir.realpathAlloc` | `dir.realPathFileAlloc(io, p, gpa)` (`[:0]u8`); absolute: `std.Io.Dir.realPathFileAbsoluteAlloc` |
| `file.read` / `readv` | `file.readStreaming(io, &.{buf})` |
| `file.pread` / `preadAll` | `file.readPositional(io, &.{buf}, offset)` / `readPositionalAll` |
| `file.write` / `writeAll` | `file.writeStreaming(io, …)` / `writeStreamingAll(io, bytes)` |
| `file.pwrite` / `pwriteAll` | `file.writePositional(io, &.{bytes}, offset)` / `writePositionalAll` |
| `file.getEndPos` / `setEndPos` | `file.length(io)` / `file.setLength(io, n)` |
| `file.seekTo` / `seekBy` / `getPos` | on the reader/writer: `fr.seekTo(n)`, `fr.seekBy(d)`, `fr.logicalPos()` |
| `file.sync()` | `file.sync(io)` |
| `file.chmod` / `chown` / `updateTimes` | `file.setPermissions` / `setOwner` / `setTimestamps`, `setTimestampsNow` |
| `File.Mode`, `default_mode` | `File.Permissions`, `File.Permissions.default_file`; `stat.permissions.toMode()` |
| `Stat.atime: Timestamp` | `?Timestamp` (file systems may not report it); `stat.mtime.nanoseconds` |
| `std.fs.selfExePath*`, `selfExeDirPath*`, `openSelfExe` | `std.process.executablePath*`, `executableDirPath*`, `openExecutable` |
| `dir.setAsCwd()` | `std.process.setCurrentDir(io, dir)` |
| `std.fs.max_path_bytes` | `std.Io.Dir.max_path_bytes` |
| `std.fs.path.relative(gpa, from, to)` | `std.fs.path.relative(gpa, cwd_path, environ_map, from, to)` (pure; pass cwd/env) |
| `std.Io.File.OpenFlags` / `CreateFlags` / `OpenMode` (0.16 aliases) | **removed in 0.17**: `std.Io.Dir.OpenFileOptions` / `CreateFileOptions` / `OpenFileOptions.Mode` |

New since 0.16: `dir.walkSelectively(gpa)` with `walker.enter(io, entry)` to
descend only where wanted (`entry.depth()`, `walker.leave()`);
`dir.renamePreserve` (no clobber); `dir.hardLink`; `dir.setFilePermissions`;
`dir.setFileOwner`. 0.17 adds appending variants of `std.fs.path.resolve` and
`relative`.

Error renames (0.16): `RenameAcrossMountPoints`/`NotSameFileSystem` →
`error.CrossDevice`; `SharingViolation` → `error.FileBusy`;
`EnvironmentVariableNotFound` → `error.EnvironmentVariableMissing`;
limited-read overflow → `error.StreamTooLong`; `Dir.rename` onto a non-empty
directory → `error.DirNotEmpty`.

---

## 11. Processes

```zig
const std = @import("std");

test "spawn, wait, capture" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "exit 3" },
        .stdin = .ignore, .stdout = .inherit, .stderr = .inherit,   // or .pipe
    });
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, term);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ "echo", "hi" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings("hi\n", result.stdout);
    try std.testing.expect(result.term.success());                   // 0.17; {f} prints "exited with code 0"

    var p = try std.process.spawn(io, .{ .argv = &.{ "echo", "piped" }, .stdout = .pipe });
    var rbuf: [256]u8 = undefined;
    var r = p.stdout.?.reader(io, &rbuf);
    const out = try r.interface.allocRemaining(gpa, .limited(4096));
    defer gpa.free(out);
    _ = try p.wait(io);
}
```

- `Child.Term = union(enum) { exited: u8, signal: std.posix.SIG, stopped:
  std.posix.SIG, unknown: u32 }` (lowercase since 0.16). `child.kill(io)`.
- A missing executable is `error.FileNotFound` from `spawn`.
- `std.process.replace(io, .{ .argv = argv })` is `execv`; it returns only on
  error.
- **0.17: choosing the executable.** `spawnPath`/`replacePath` are gone. Every
  `SpawnOptions`/`RunOptions`/`ReplaceOptions` has `.exe`:
  `.detect` (default), `.search` (PATH), `.path = dir` (relative to a
  `std.Io.Dir`), `.file = file`, `.explicit = .{ .dir = .cwd(), .path =
  "/bin/echo" }` (lets `argv[0]` differ from the binary).
  `disable_aslr` was removed; `inherit_dirs`, `inherit_files`,
  `ReplaceOptions.cwd`, `start_suspended` are new.
- `std.process.getUserInfo(io, name)` now takes `io`.
- Spawning through `global_single_threaded` fails with `error.OutOfMemory`.
- Memory locking (was `std.posix.mlock*`):
  `try std.process.lockMemory(page_aligned_slice, .{ .on_fault = true });`
  (the slice type is `[]align(std.heap.page_size_min) const u8`),
  `try std.process.lockMemoryAll(.{ .current = true, .future = true });`

---

## 12. Networking and HTTP

`std.net` became `std.Io.net` in 0.16; 0.17 keeps the API and adds timeouts
and ancillary data.

```zig
const net = std.Io.net;
const addr = try net.IpAddress.parse("127.0.0.1", 0);
var server = try addr.listen(io, .{ .reuse_address = true });
defer server.deinit(io);
const port = server.socket.address.getPort();

const conn = try (try net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
defer conn.close(io);
var accepted = try server.accept(io);
defer accepted.close(io);

var wbuf: [64]u8 = undefined;
var sw = conn.writer(io, &wbuf);
try sw.interface.writeAll("ping");
try sw.interface.flush();
var rbuf: [64]u8 = undefined;
var sr = accepted.reader(io, &rbuf);
const got = try sr.interface.takeArray(4);
```

- `IpAddress` is a union with `.ip4`/`.ip6`; `Ip4Address` is
  `.{ .bytes = .{ 127, 0, 0, 1 }, .port = p }`.
- `Stream` has no `read`/`writeAll` of its own in practice: use
  `stream.reader(io, &buf).interface` / `stream.writer(io, &buf).interface`.
  **0.17 bug:** the new `Stream.read(io, bufs)` fails to compile inside std
  (*type 'Io.net.Stream.ReadResult' cannot be destructured*); use
  `(try stream.readWithControl(io, &bufs, &.{})).data_len` or the reader.
- 0.17 error-set changes break exhaustive switches: `ConnectionTimedOut` added
  to stream reader/writer and socket send/receive errors; `Timeout` removed
  from `Stream.Reader.Error`; `AccessDenied`/`ConnectionRefused` added to
  bind/listen/connect errors. `BindOptions/ListenOptions.ip6_only` is now
  `?bool` (`null` = OS default).
- New in 0.17: `Socket.sendTimeout`, `sendManyTimeout`,
  `readWithControl`/`readerWithControl` and `net.cmsg` helpers (fd passing).
- Windows `std.Io.net` uses AFD directly, not `ws2_32.dll`. Non-IP sockets are
  not implemented. `Io.Evented` has no networking.

HTTP client:

```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();

// One call:
var body: std.Io.Writer.Allocating = .init(gpa);
defer body.deinit();
const res = try client.fetch(.{
    .location = .{ .url = "http://example.com/" },
    .method = .GET,
    .response_writer = &body.writer,
});
// res.status, body.written()

// Step by step:
var req = try client.request(.GET, try std.Uri.parse("http://example.com/"), .{});
defer req.deinit();
try req.sendBodiless();
var redirect_buf: [1024]u8 = undefined;
var resp = try req.receiveHead(&redirect_buf);
var transfer_buf: [4096]u8 = undefined;
const rdr = resp.reader(&transfer_buf);
```

The client queries every configured nameserver concurrently, connects to the
first answer and cancels the rest; it works with `-fsingle-threaded`. 0.17:
`std.http.Method` gained `.QUERY` (exhaustive switches break);
`Uri.getHost(&buf)` → `std.Io.net.HostName.fromUri(uri, &buf)` (validates;
errors `UriMissingHost`, `NameTooLong`, `InvalidHostName`);
`Uri.getHostAlloc` removed; `ConnectionPool.resize(io, n)` now returns
`Cancelable!void`.

---

## 13. Concurrency, sync, time, entropy

### 13.1 Futures and groups

```zig
fn add(a: u32, b: u32) u32 { return a + b; }

var fut = io.async(add, .{ 1, 2 });          // may run synchronously; infallible
const sum = fut.await(io);                    // 3

var group: std.Io.Group = .init;              // many tasks, one lifetime
defer group.cancel(io);
for (items) |item| group.async(io, work, .{ io, item });   // NOTE: Group.async takes io FIRST
try group.await(io);

var f2 = try io.concurrent(add, .{ 2, 2 });   // MUST run concurrently; error.ConcurrencyUnavailable
_ = f2.await(io);
```

- Argument shapes differ: `io.async(func, args)` vs
  `group.async(io, func, args)`.
- Resource-returning futures: `var f = io.async(open, .{…}); defer if
  (f.cancel(io)) |r| r.deinit() else |_| {};` then `const r = try f.await(io);`.
- 0.17 dropped the documented guarantee that a task has *started* when
  `async` returns; it is only guaranteed to have run once `await`/`cancel`
  returns.
- `std.Thread.spawn(.{}, func, args)` / `thread.join()` still exist for raw
  OS threads. There is no thread pool; use `Io.Group`.

### 13.2 Cancelation (spelled with one `l`)

Requests may or may not be acknowledged; acknowledged I/O returns
`error.Canceled`. Handle it by (1) propagating it, (2) calling `io.recancel()`
and not propagating, or (3) `io.swapCancelProtection()` where it is provably
unreachable. Only the requester may swallow it. `io.checkCancel()` is a manual
cancelation point. `std.debug.print` and stack dumps block cancelation (0.17).

Lower-level: `Io.Batch` (operation-level concurrency over
`FileReadStreaming`, `FileWriteStreaming`, `NetReceive`, `DeviceIoControl`),
`Io.Select` (wait for one of several tasks), `Io.Queue(T)` (MPMC, bounded:
`var q: std.Io.Queue(u32) = .init(&buf); try q.putOne(io, x); const v = try
q.getOne(io);`).

### 13.3 Sync primitives

| Type | Init | Use |
|---|---|---|
| `std.Io.Mutex` | `.init` | `try m.lock(io)` (cancelable) or `m.lockUncancelable(io)`; `m.unlock(io)` |
| `std.Io.Condition` | `.init` | `try c.wait(io, &m)`; `c.waitTimeout(io, &m, timeout)` (0.17); `c.signal(io)`, `c.broadcast(io)` |
| `std.Io.Event` | `.unset` | `ev.set(io)`, `try ev.wait(io)`, `waitTimeout`, `reset` |
| `std.Io.Semaphore` | `.{}` | `sem.post(io)`, `try sem.wait(io)`, `sem.waitTimeout(io, timeout)` (0.17) |
| `std.Io.RwLock` | `.init` | `try rw.lockShared(io)`, `rw.unlockShared(io)`, `lock`/`unlock` |
| `std.Io.Group` | `.init` | tasks (§13.1) |

```zig
var m: std.Io.Mutex = .init;
var c: std.Io.Condition = .init;
{
    try m.lock(io);
    defer m.unlock(io);
    while (!ready) try c.wait(io, &m);
}
```

`waitTimeout` returns `error{ Timeout, Canceled }`.

Futex: three free functions, no type. `T` must be 4 bytes.

```zig
pub fn futexWait(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T) Cancelable!void
pub fn futexWaitTimeout(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T, timeout: Timeout) Cancelable!void
pub fn futexWake(io: Io, comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void
```

A timeout expiry returns success; re-read the word. `Timeout` is
`.none`, `.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }`,
or `.{ .deadline = clock_timestamp }`. Std's futex helpers are
process-private.

### 13.4 Time

`std.time` holds only unit constants (`ns_per_ms`, `ns_per_s`, `us_per_ms`,
`ms_per_s`, …) and `std.time.epoch`. Everything else is on `std.Io`:

| Task | 0.17 |
|---|---|
| monotonic start | `const t0 = std.Io.Clock.awake.now(io);` (an `Io.Timestamp`) |
| elapsed | `t0.untilNow(io, .awake).toNanoseconds()` (an `Io.Duration`) |
| wall clock | `std.Io.Clock.real.now(io).toSeconds()` / `.toMilliseconds()` / `.toNanoseconds()` |
| clock-tagged form | `const a = std.Io.Clock.Timestamp.now(io, .awake); … a.durationTo(b).raw.toNanoseconds()` |
| sleep | `try io.sleep(.fromMilliseconds(n), .awake);` (or `std.Io.sleep(io, dur, .awake)`) |
| durations | `std.Io.Duration.fromNanoseconds/fromMicroseconds/fromMilliseconds/fromSeconds`, `.toNanoseconds()` … |
| resolution | `try std.Io.Clock.awake.resolution(io)` |
| compare | `ts.compare(.lt, other)` (0.17) |

Clocks: `.awake` (monotonic, excludes suspend), `.boot`, `.real` (wall),
`.cpu_process`, `.cpu_thread`.

### 13.5 Entropy

```zig
io.random(&buf);                                  // fast, non-crypto
try io.randomSecure(&buf);                        // crypto-grade, from outside the process; error.EntropyUnavailable
const src: std.Random.IoSource = .{ .io = io };   // std.Random interface over Io
const rng = src.interface();
var prng: std.Random.DefaultPrng = .init(seed);   // deterministic PRNG, no Io needed
```

---

## 14. Allocators

The interface is `std.mem.Allocator`: `alloc`, `free`, `create`, `destroy`,
`dupe`, `realloc`, `resize`, `remap`. Alignment is `std.mem.Alignment` (an
enum of log2 values: `.@"16"`, `.of(T)`), not a byte count.

| Allocator | Use |
|---|---|
| `std.heap.SafeAllocator` | **0.17** leak/misuse-checking GPA; replaces `DebugAllocator` (deprecated) and `GeneralPurposeAllocator` (removed in 0.16) |
| `std.heap.smp_allocator` | fast thread-safe GPA for release builds; a global value, no setup/deinit |
| `std.heap.ArenaAllocator` | `.init(child)`, `.allocator()`, frees all at `deinit()`; lock-free and threadsafe (0.16) |
| `std.heap.page_allocator` | whole pages; a backing allocator, not for small objects |
| `std.heap.c_allocator` | `malloc`; needs libc |
| `std.heap.FixedBufferAllocator` | `.init(&buf)` |
| `std.heap.BufferFirstAllocator` | **0.17**: buffer first, then a fallback allocator (replaces `stackFallback`) |
| `std.heap.MemoryPool(T)` | `.empty`, `try pool.create(gpa)`, `pool.destroy(p)`, `pool.deinit(gpa)` (0.17: `memory_pool.Managed*`, `MemoryPoolAligned/Extra` aliases removed → `std.heap.memory_pool.Aligned/Extra`) |
| `std.testing.allocator` | in tests; SafeAllocator-backed; a leak fails the test |
| `std.testing.failing_allocator`, `std.testing.FailingAllocator` | exercise `error.OutOfMemory` paths |

`std.heap.ThreadSafeAllocator` and `std.heap.GeneralPurposeAllocator` are
gone (0.16).

```zig
const std = @import("std");

test "0.17 allocator APIs" {
    var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{}); // options: .stack_trace_frames, .check_write_after_free, .canary
    const gpa = sa.allocator();
    {
        const s = try gpa.print("{s}={d}", .{ "x", 1 }); // was std.fmt.allocPrint
        defer gpa.free(s);
        const z = try gpa.printSentinel("{d}", .{42}, 0); // was std.fmt.allocPrintSentinel / allocPrintZ
        defer gpa.free(z);
        const d = try gpa.dupeSentinel(u8, "hi", 0); // was gpa.dupeZ(u8, "hi")
        defer gpa.free(d);
        const p = try gpa.alignedCreate(u32, .@"16"); // new in 0.17
        defer gpa.destroy(p);

        var stack_buf: [256]u8 = undefined;
        var bfa: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa); // was std.heap.stackFallback(256, gpa)
        const small = try bfa.allocator().alloc(u8, 16);
        bfa.allocator().free(small);

        var buf: [32]u8 = undefined;
        const t = try std.mem.print(&buf, "{d} items", .{3}); // was std.fmt.bufPrint
        try std.testing.expectEqualStrings("3 items", t);
        const tz = try std.mem.printSentinel(&buf, "{s}", .{"x"}, 0); // was std.fmt.bufPrintZ (removed)
        _ = tz;
    } // everything freed before the leak check below

    try std.testing.expectEqual(0, sa.deinit()); // returns the LEAK COUNT (usize), not .ok/.leak
}
```

- `SafeAllocator.deinit()` logs leaks and returns their count;
  `deinitLog(false)` returns the count without logging. `deinit() == .leak`
  is a compile error (*incompatible types: 'usize' and '@EnumLiteral()'*):
  write `if (sa.deinit() != 0) …`.
- SafeAllocator guarantees: thread-safe; never reuses memory (use-after-free
  segfaults or is detected); double free, mismatched free and racing
  resize/free panic; allocations from another instance with a different
  `canary` panic.
- **Each allocation captures a stack trace** (`.stack_trace_frames`, 7 by
  default in debug builds), which dominates its cost. Measured on Apple M5,
  200k create+destroy: 6.1 s with the defaults, 53 ms with
  `.stack_trace_frames = 0`, 7 ms on `smp_allocator` (0.16's
  `DebugAllocator(.{})`: 6.5 s). `init.gpa` and `std.testing.allocator` use
  the defaults. For allocation-heavy debug runs, use an arena or a
  `SafeAllocator` with `.stack_trace_frames = 0`.
- A test that leaks still prints `OK` on its own line; the leak report
  follows, the summary says `N tests leaked memory`, and the run exits 1.
- `BufferFirstAllocator` with a typed buffer: `var items: [8]Item =
  undefined; var bfa: std.heap.BufferFirstAllocator = .init(@ptrCast(&items),
  gpa);`. **The release notes call this `StackFallbackAllocator`; that name
  does not exist in 0.17.0.**
- Deprecated but compiling: `std.heap.DebugAllocator`, `std.heap.Check`,
  `std.fmt.allocPrint`, `std.fmt.allocPrintSentinel`, `std.fmt.bufPrint`,
  `std.fmt.bufPrintSentinel`, `std.fmt.BufPrintError` (→ `std.mem.PrintError`).
  Removed: `std.fmt.bufPrintZ`, `Allocator.dupeZ`, `std.heap.stackFallback`.
- A custom test runner that did `var gpa_instance: DebugAllocator(.{}) =
  .{}` and `== .leak` must become `.init(std.heap.page_allocator, .{})` and
  `!= 0`.

Custom allocator (vtable unchanged since 0.15):

```zig
const std = @import("std");

const Counting = struct {
    backing: std.mem.Allocator,
    live: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, a, ra) orelse return null;
        self.live += 1;
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(m, a, n, ra);
    }
    /// Like resize but may move; null means "allocate, copy, free instead".
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(m, a, ra);
        self.live -= 1;
    }
};

test Counting {
    var c: Counting = .{ .backing = std.testing.allocator };
    const a = c.allocator();
    const bytes = try a.realloc(try a.alloc(u8, 100), 5000);
    a.free(bytes);
    try std.testing.expectEqual(0, c.live);
}
```

---

## 15. Containers

All std containers are **unmanaged** (the allocator is passed per call) and
initialise with the `.empty` decl literal. Struct-literal initialisation
(`.{}`) does not compile for `ArrayList` (its fields have no defaults).

### 15.1 `std.ArrayList(T)`

```zig
const std = @import("std");

const Module = struct {
    names: std.ArrayList([]const u8) = .empty,     // not `= .{}`
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
    _ = list.orderedRemove(1);                                  // {0, 2, 3, 4, 5}
    _ = list.swapRemove(0);                                     // {5, 2, 3, 4}
    try std.testing.expectEqual(@as(?u32, 4), list.pop());      // {5, 2, 3}
    try std.testing.expectEqual(@as(?u32, 3), list.last());     // 0.17; was getLastOrNull()
    if (list.lastPtr()) |p| p.* += 1;                           // 0.17
    try std.testing.expectEqual(4, list.last().?);              // was getLast()

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.print(gpa, "{d}+{d}", .{ 1, 2 });                  // formatted append
    try std.testing.expectEqualStrings("1+2", text.items);

    var buf: [4]u8 = undefined;
    var bounded: std.ArrayList(u8) = .initBuffer(&buf);         // the BoundedArray replacement
    try bounded.appendSliceBounded("abcd");                     // error.OutOfMemory when full
    try std.testing.expectError(error.OutOfMemory, bounded.appendBounded('e'));

    var m: Module = .{};
    defer m.names.deinit(gpa);
    try m.names.append(gpa, "main");

    const owned = try list.toOwnedSlice(gpa);                   // list is empty again
    gpa.free(owned);
}
```

- `std.ArrayListUnmanaged` and `std.ArrayListAligned*` are deprecated
  aliases. The managed list survives as deprecated `std.array_list.Managed(T)`
  (`.init(gpa)`, `append(x)`).
- **0.17 pointer stability:** `list.lockPointers()` / `list.unlockPointers()`
  (nestable) make any operation that could move or free the items
  (growth past capacity, `pop`, `insert`, removes, `shrink*`, `clear*`,
  `deinit`, `toOwnedSlice`) panic while locked, in safe modes. The new
  `pointer_stability` field has no default, so construct lists with `.empty`,
  `.initBuffer(&buf)` or `try .initCapacity(gpa, n)`, never a struct literal
  (*missing struct field: pointer_stability*).
- An unmanaged list has no `.writer()`. Use `list.print(gpa, …)` or a
  `std.Io.Writer.Allocating` (`fromArrayList` / `toArrayList` to convert).

### 15.2 Hash maps

```zig
var ids: std.StringHashMapUnmanaged(u32) = .empty;      // also std.AutoHashMapUnmanaged(K, V), std.HashMapUnmanaged(K, V, Ctx, max_load)
defer ids.deinit(gpa);
try ids.put(gpa, "a", 1);
const gop = try ids.getOrPut(gpa, "b");
if (!gop.found_existing) gop.value_ptr.* = 2;
_ = ids.get("b");                                       // no allocator for get/getPtr/contains/remove/count/iterator
_ = ids.remove("a");
var it = ids.iterator();
while (it.next()) |e| _ = .{ e.key_ptr.*, e.value_ptr.* };

var managed = std.StringHashMap(u32).init(gpa);          // managed hash maps still exist
defer managed.deinit();
```

Insertion-ordered (array) hash maps moved in 0.16 and are unmanaged only:

```zig
var m: std.array_hash_map.String(V) = .empty;            // also .Auto(K, V), .Custom(K, V, Ctx, store_hash)
defer m.deinit(gpa);
try m.put(gpa, "k", v);
_ = m.orderedRemove("k");                                // removal must choose: orderedRemove / swapRemove
for (m.keys(), m.values()) |k, val| _ = .{ k, val };
```

`std.AutoArrayHashMapUnmanaged`/`StringArrayHashMapUnmanaged`/
`ArrayHashMapUnmanaged` are deprecated aliases; the managed
`std.AutoArrayHashMap` family is gone. 0.17: `ArrayHashMap.setKey(i, k)` no
longer takes an allocator and cannot fail; hash-map `lockPointers` nests.
String-keyed maps do not copy keys: keys must outlive the map.

### 15.3 Bit sets, enum containers, others

| 0.16 | 0.17 |
|---|---|
| `std.bit_set.IntegerBitSet(n)` | `std.bit_set.Integer(n)` |
| `std.bit_set.ArrayBitSet(MaskInt, n)` | `std.bit_set.Array(MaskInt, n)` |
| `std.StaticBitSet(n)` | `std.bit_set.Static(n)` |
| `std.DynamicBitSetUnmanaged` | `std.bit_set.Dynamic` (`try .initEmpty(gpa, n)`, `deinit(gpa)`) |
| `std.DynamicBitSet` (managed) | `std.bit_set.DynamicManaged` (deprecated) |
| `.initEmpty()` / `.initFull()` on static sets and `EnumSet` | `.empty` / `.full` (**removed**) |
| `std.EnumMap(E, V){}` | `.empty` (default fields deprecated) |

New: `setAll()`/`unsetAll()` on every bit set; `MultiArrayList.swap`;
`std.StaticStringMap(E).initEnum()`.

```zig
var seen: std.bit_set.Static(64) = .empty;
seen.set(3);
const Kw = enum { kw_if, kw_else };
const keywords = std.StaticStringMap(Kw).initComptime(.{ .{ "if", .kw_if }, .{ "else", .kw_else } });
_ = keywords.get("else");                                 // ?Kw
var dq: std.Deque(u32) = .empty;                          // pushBack/pushFront(gpa, x), popFront/popBack()
var pq: std.PriorityQueue(u32, void, lessThan) = .empty;  // push(gpa, x), pop(), peek()  (0.16 renames)
var mal: std.MultiArrayList(struct { a: u8, b: u32 }) = .empty;
```

`std.SinglyLinkedList`/`std.DoublyLinkedList` are intrusive (embed a `Node`,
recover the parent with `@fieldParentPtr`); 0.17 renames
`DoublyLinkedList.pop` → `popLast` (old name deprecated) and makes `remove`
take a const pointer. `std.SegmentedList`, `std.BoundedArray`,
`std.fifo.LinearFifo`, `std.RingBuffer` are gone. Sorting: `std.mem.sort(T,
items, ctx, lessThan)` (stable), `std.mem.sortUnstable`, `std.sort.asc(T)`.

---

## 16. Strings, `std.mem`, formatting

### 16.1 `std.mem`

| Need | Call |
|---|---|
| equality / prefix / suffix | `std.mem.eql(u8, a, b)`, `startsWith`, `endsWith` |
| find | `find`, `findScalar`, `findAny`, `findLast`, `findScalarLast`, `findPos`, `findDiff` (`indexOf*`/`lastIndexOf*` are deprecated aliases) |
| split once | `std.mem.cut(u8, s, "=")` → `?struct { []const u8, []const u8 }`; `cutScalar`, `cutLast`, `cutLastScalar`, `cutPrefix`, `cutSuffix` |
| split | `splitScalar`, `splitSequence`, `splitAny` (keep empty fields); `tokenizeScalar`, `tokenizeAny` (skip them) |
| trim | `trim`, `trimStart`, `trimEnd` (`trimLeft`/`trimRight` removed in 0.16) |
| join / concat / replace / count | `join(gpa, ", ", parts)`, `concat(gpa, u8, &.{a, b})`, `replaceOwned(u8, gpa, s, "a", "b")`, `count(u8, s, "a")` |
| format into a slice | `std.mem.print(&buf, fmt, args)`, `printSentinel(&buf, fmt, args, 0)` (0.17) |
| sentinel copies / compare | `copySentinel`, `copySentinelInclusive`, `lessThanZ` (0.17) |
| packed ints | `readPackedInt(T, bytes, bit_offset, endian)`, `writePackedInt(…)` (the `*Native`/`*Foreign` variants are removed in 0.17) |
| byte swap a struct | `std.mem.byteSwap(T, &x)` (extern/packed only; was `byteSwapAllFields`) |
| **count check** | `std.mem.containsAtLeastScalar(T, haystack, element, minimum)` — **argument order changed in 0.17** |
| ASCII | `std.ascii.isDigit`, `isAlphabetic`, `isWhitespace`, `toLower`, `findIgnoreCase` (`indexOfIgnoreCase*` removed in 0.17) |
| parse numbers | `std.fmt.parseInt(i64, s, 10)` (base 0 reads `0x`/`0o`/`0b`, allows `_`), `std.fmt.parseFloat(f64, s)` |
| enum from text | `std.meta.stringToEnum(E, s)` |

```zig
const line = "  key = value  ";
const key, const value = std.mem.cutScalar(u8, std.mem.trim(u8, line, " "), '=').?;
_ = std.mem.trimEnd(u8, key, " ");
_ = std.mem.trimStart(u8, value, " ");
```

### 16.2 Format specifiers (verified on 0.17)

Grammar: `{[position][specifier]:[fill][alignment][width].[precision]}`.
Positional `{0s}`, named `{[name]s}` with `.{ .name = x }`, literal braces
`{{` `}}`.

| Spec | For | Example → output |
|---|---|---|
| `{d}` | integers, floats | `{d:0>4}` 42 → `0042`; `{d:.2}` 3.14159 → `3.14`; `{d}` 2.5 → `2.5` |
| `{s}` | `[]const u8`, `[*:0]const u8`, byte arrays | `{s:<4}` "ab" → `ab␣␣`; **`{s:10}` → right-aligned** |
| `{c}` / `{u}` | byte as char / `u21` code point | `A`, `é` |
| `{x}` `{X}` | hex; byte slices as hex pairs | 255 → `ff`; "AB" → `4142` |
| `{b}` `{o}` | binary, octal | 5 → `101`; 8 → `10` |
| `{e}` | scientific, shortest round-trip | 1234.5 → `1.2345e3`; 1000.0 → `1e3` |
| `{t}` | tag name of an enum/tagged union, error name | `.green` → `green`; `error.Oops` → `Oops` |
| `{?}` / `{?d}` / `{?s}` | optionals | null → `null` |
| `{!}` | error unions | payload or error |
| `{f}` | **calls the `format` method** | |
| `{any}` | default rendering; skips `format` | `.{ .x = 1, .y = -2 }`; `[]const u8` → `{ 97, 98 }` |
| `{*}` | pointer address | |
| `{B}` / `{Bi}` | byte sizes SI / IEC | 2048 → `2KiB` |
| `{q}` | **0.17**: Zig double-quoted string literal, UTF-8 passes through | `"a\"b\nc"` |
| `{qf}` | **0.17**: call `format`, then quote/escape its output | |

Bare `{}`: numbers, bools, enums (`.red`), errors, structs (as `{any}`).
Strings need `{s}` (*cannot format slice without a specifier (i.e. {s}, {x},
{b64}, or {any})*), optionals `{?}` (*cannot print optional without a
specifier*). **A struct with a `format` method printed with `{}` or `{any}`
prints its fields — only `{f}` calls `format`.**

### 16.3 Custom formatting

```zig
const Point = struct {
    x: i32,
    y: i32,
    pub fn format(p: Point, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("({d}, {d})", .{ p.x, p.y });
    }
};
// std.debug.print("{f}\n", .{p});  →  (1, -2)

// Several renderings of one type: return a std.fmt.Alt
const Name = struct {
    text: []const u8,
    fn quoted(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("\"{s}\"", .{text});
    }
    pub fn fmtQuoted(n: Name) std.fmt.Alt([]const u8, quoted) {
        return .{ .data = n.text };
    }
};
// "{f}" with name.fmtQuoted()
```

Renamed in 0.16: `std.fmt.Formatter` → `std.fmt.Alt`, `std.fmt.format` →
`writer.print`, `std.fmt.FormatOptions` → `std.fmt.Options`.
`std.zig.fmtString(s)` escapes for a Zig string literal (`{f}`). 0.17 adds
`writer.printStringEscaped`.

---

## 17. ZON and JSON

### 17.1 `std.zon` (reworked in 0.17)

```zig
const std = @import("std");

const Config = struct { name: []const u8, port: u16 = 8080, tags: []const []const u8 = &.{} };

test "zon" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: std.zon.parse.Diagnostics = undefined;           // initialised by the callee
    const cfg = std.zon.parse.fromSlice(Config, .{
        .gpa = gpa,
        .arena = arena,                                       // the result lives in the arena
        .source = ".{ .name = \"svc\", .tags = .{ \"a\", \"b\" } }",
        .diagnostics = &diag,
    }) catch |err| switch (err) {
        error.ParseZon => diag.fatal("config.zon"),            // or diag.log(path) / "{f}" with diag.fmt(path)
        error.OutOfMemory => |e| return e,
    };
    try std.testing.expectEqual(8080, cfg.port);

    var overlay = cfg;                                        // layered config: overwrite fields present in source
    try std.zon.parse.updateFromSlice(Config, &overlay, .{
        .gpa = gpa, .arena = arena, .source = ".{ .port = 9000 }", .diagnostics = &diag,
    });
    try std.testing.expectEqual(9000, overlay.port);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(cfg, .{}, &out.writer);
}
```

| 0.16 | 0.17 |
|---|---|
| `std.zon.parse.fromSlice(T, gpa, src, &diag, .{})` (no-alloc types) | `std.zon.parse.fromSliceNoAlloc(T, .{ .gpa, .arena, .source, .diagnostics })` |
| `std.zon.parse.fromSliceAlloc(…)` + `std.zon.parse.free(gpa, v)` | `std.zon.parse.fromSlice(T, .{ … })`, result in `arena`; no `free` |
| `var diag: Diagnostics = .{}; defer diag.deinit(gpa);` + `"{f}"` | `var diag: Diagnostics = undefined;` + `diag.log(path)` / `diag.fatal(path)` / `diag.fmt(path)`; no `deinit` |
| options `ignore_unknown_fields`, `free_on_error` | `std.zon.parse.Options{ gpa, arena, source, diagnostics, ignore_unknown_fields = false }` |
| — | `updateFromSlice`, `updateFromSliceNoAlloc`, `updateFromZoir*`, `fromZoirNoAlloc`, `std.zon.fmt(value, .{})` for `{f}` |
| `Serializer.string(s)` / `codePoint(c)` | `string(s, .{})` / `codePoint(c, .{})` |
| non-ASCII escaped by default | raw UTF-8; `.escape_non_ascii = true` to escape |

**The release notes write `std.zon.fromSlice`; it is `std.zon.parse.fromSlice`.**

### 17.2 `std.json` (unchanged in 0.17)

```zig
const parsed = try std.json.parseFromSlice(Config, gpa, json_text, .{ .ignore_unknown_fields = true });
defer parsed.deinit();
const cfg = parsed.value;

var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2 }, &out.writer);
// or "{f}" with std.json.fmt(cfg, .{})
```

0.17 only adds `max_value_len` enforcement for `[:0]const u8` fields.

---

## 18. The POSIX and libc layer

`std.posix` is deliberately thin since 0.16. Two paths:

- **High level:** `std.Io.File` / `std.Io.Dir` with an `io` parameter.
- **Low level** (an OS-abstraction layer that should not take `io`): call the
  `std.c.*` externs directly (libc must be linked; it is implicit on macOS).
  They return `c_int` with the 0 / −1 convention; read `std.c.errno(rc)`.

| Gone from `std.posix` | Low level | High level |
|---|---|---|
| `close(fd)` | `_ = std.c.close(fd)` | `file.close(io)` |
| `fstat` | `var st: std.c.Stat = undefined; if (std.c.fstat(fd, &st) != 0) …` | `file.stat(io)` |
| `ftruncate` | `std.c.ftruncate(fd, len)` | `file.setLength(io, len)` |
| `fsync` | `std.c.fsync(fd)` | `file.sync(io)` |
| `unlink` | `std.c.unlink(path.ptr)` (`[*:0]const u8`) | `dir.deleteFile(io, path)` |
| `write`, `open`, `pipe`, `fork`, `waitpid`, `exit`, `isatty`, `getenv`, `getrandom` | `std.c.*` | `std.Io` / `std.process` |
| `mlock`, `mlockall` | — | `std.process.lockMemory*` |

Still in `std.posix`: `read`, `mmap`, `munmap`, `msync`, `madvise`, `mprotect`,
`fdatasync`, `openatZ`, `poll`, `tcgetattr`, `tcsetattr`, `sigaction`,
`kill` (typed `SIG`), plus `cmsghdr`/`cmsg_align` (0.17).

- `std.posix.PROT` is a packed struct type: `.{ .READ = true, .WRITE =
  true }` (not `PROT.READ | PROT.WRITE`; `mmap`'s `prot` takes the struct).
  mmap flags are struct fields too.
- Process liveness check: `std.c.kill(pid, @enumFromInt(0))`
  (`std.posix.kill`'s `SIG` has no named 0 on macOS); distinguish `.PERM`
  (alive) from `.SRCH` (gone) with `std.c.errno(rc)`.
- Clocks without `Io`: `var ts: std.c.timespec = undefined; _ =
  std.c.clock_gettime(.MONOTONIC, &ts);` — but prefer
  `global_single_threaded` + `std.Io.Clock`.
- `ucontext_t` is not provided; define it if a signal handler needs it.
- 0.17: `std.c.getgrnam` correctly returns `?*group`; many libc
  declarations were added; `std.os.requiresLibC()` is new.

---

## 19. Panics, debugging, tests, fuzzing

### 19.1 Debug output

`std.debug.print(fmt, args)` writes to stderr immediately, ignores errors,
bypasses `Io`, and (0.17) blocks cancelation while running. `std.debug.assert`
is checked in Debug/ReleaseSafe and is illegal behaviour when false in
Fast/Small. `@panic(msg)`, `std.debug.panic(fmt, args)`. `std.log.{err,
warn, info, debug}` with scopes via `std.log.scoped(.name)`.

Stack traces: `std.debug.dumpCurrentStackTrace(.{})`,
`std.debug.captureCurrentStackTrace(.{}, &addr_buf)`,
`std.debug.dumpStackTrace(&trace)`, `std.debug.writeStackTrace(&trace,
terminal)`; `@errorReturnTrace()`. `StackUnwindOptions{ first_address,
context, allow_unsafe_unwind = false }`. `std.debug.StackIterator` is not
public. `std.debug.SafetyLock` gained `lockShared`/`unlockShared` (0.17).

### 19.2 Custom panic handlers

```zig
const std = @import("std");

pub const panic = std.debug.FullPanic(onPanic);        // unaffected by 0.17

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // flush buffered program output here, then:
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

pub fn main() void {}
```

`std.debug.simple_panic` and `std.debug.no_panic` are ready-made handlers. A
hand-written **`pub const panic = struct { … }` namespace must, in 0.17, also
declare** `unexpectedErrorCode` and `loadUninstantiableType` (*'std.lang.panic'
missing 'unexpectedErrorCode'*). Copy them:
`pub const unexpectedErrorCode = std.debug.simple_panic.unexpectedErrorCode;`
`pub const loadUninstantiableType = std.debug.simple_panic.loadUninstantiableType;`

### 19.3 Tests

```zig
const std = @import("std");

fn double(n: i64) i64 {
    return n * 2;
}

// A plain comment. `///` before a test is a compile error.
test double {
    try std.testing.expectEqual(@as(i64, 8), double(4));
}

test "the testing namespace" {
    const gpa = std.testing.allocator;              // leaks fail the test
    const io = std.testing.io;                      // an Io for tests
    const s = try gpa.print("{d}", .{double(21)});
    defer gpa.free(s);
    try std.testing.expectEqualStrings("42", s);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &.{ 1, 2 });
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u8, "x", 10));
    var tmp = std.testing.tmpDir(.{});              // scratch std.Io.Dir under .zig-cache/tmp
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
}
```

`expectEqual(expected, actual)` compares at the peer type, so a bare literal
works as `expected`. 0.17 renames the internal `std.testing.print*` helpers to
`failPrint*` and adds `std.testing.WriterIndirect`. `std.testing.allocator`
outside a test is *error: not testing*. `zig build test --test-timeout 30s`
kills hung tests.

### 19.4 Fuzzing (0.16 API, unchanged in 0.17)

Fuzz tests receive a `*std.testing.Smith` (structured value generator), not
`[]const u8`:

```zig
test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    var sum: u64 = 0;
    while (!smith.eos()) sum += smith.value(u8);   // also bytes(buf), slice(buf), valueRangeAtMost(T, lo, hi), boolWeighted, eosWeightedSimple
    try std.testing.expect(sum != 1234);
}
```

Run with `zig build test --fuzz -Doptimize=fast` (multiprocess `-j N`;
crashing inputs are saved and replayable via
`std.testing.FuzzInputOptions.corpus`).

---

## 20. The build system

### 20.1 What changed architecturally (0.17)

`zig build` now runs your `build.zig` in a separate **configurer**
executable (compiled in Debug) that serialises the build graph to a compact
binary configuration. A separately cached, optimised **maker** executable
does package management and executes the graph. Consequences:

- `build.zig` only *describes* the build. Anything that ran at make time
  inside the build runner — custom `makeFn` steps, `LazyPath.getPath()`,
  reading install paths — is gone.
- The configuration is cached; `build()` does not re-run unless `build.zig`
  content or `-D` options change (§4.1.3).
- `zig build -- args` no longer reaches `build.zig` (`b.args` is gone); the
  Run step forwards them (`addPassthruArgs`).
- There is no "build runner" to override (`--build-runner` is gone); tools
  integrate through the **Build Server Protocol** (`zig build --listen=-`).
  ZLS does not fully work with 0.17.0 yet for this reason.
- Package management (fetch, git, TLS, compression, `build.zig.zon`
  parsing) moved out of the compiler into the build system, compiled in
  ReleaseSafe. The first `zig build` after installing Zig compiles the
  configurer and maker once (a few seconds).

### 20.2 A complete 0.17 `build.zig` (verified)

exe + library module + tests + run + C source + options + path dependency +
fmt check + generated file:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});            // std.lang.Optimize: .debug .safe .fast .small

    const greet = b.option(bool, "greet", "Print a greeting") orelse true;
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match") orelse &[0][]const u8{};

    const options = b.addOptions();
    options.addOption(bool, "greet", greet);
    options.addOption(bool, "is_debug", optimize == .debug);   // was .Debug

    const localdep = b.dependency("localdep", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("myproj", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "localdep", .module = localdep.module("localdep") }},
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "myproj", .module = mod }},
    });
    exe_mod.addOptions("build_options", options);              // @import("build_options")
    exe_mod.addIncludePath(b.path("include"));
    exe_mod.addCSourceFiles(.{ .files = &.{"csrc/cmath.c"}, .flags = &.{ "-Wall", "-Wextra" } });
    if (optimize == .debug) exe_mod.addCMacro("MYPROJ_DEBUG", "1");
    exe_mod.strip = switch (optimize) {
        .debug, .safe => false,
        .fast, .small => true,
    };

    const exe = b.addExecutable(.{ .name = "myproj", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();                                  // was: if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod, .filters = test_filters })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe_mod, .filters = test_filters })).step);

    const fmt = b.addFmt(.{ .paths = b.pathList(&.{ "src", "build.zig", "build.zig.zon" }), .check = true });
    b.step("fmt", "Check formatting").dependOn(&fmt.step);

    const gen = b.addSystemCommand(&.{ "sh", "-c", "echo generated > \"$0\"" });
    const gen_out = gen.addOutputFileArg2("gen.txt", .{});      // addOutputFileArg is deprecated
    b.getInstallStep().dependOn(&b.addInstallFile(gen_out, "share/gen.txt").step);
}
```

```zig
// build.zig.zon
.{
    .name = .myproj,                        // enum literal, not a string (0.16)
    .version = "0.0.0",
    .fingerprint = 0x8222dc158e194c9c,      // required (0.16); `zig build` suggests one if missing
    .minimum_zig_version = "0.17.0",        // informational; not enforced
    .dependencies = .{
        .localdep = .{ .path = "deps/localdep" },
        // .foo = .{ .url = "…", .hash = "…", .lazy = true },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "csrc", "include", "deps" },
}
```

`zig init` (0.17) generates the same files as 0.16 (`build.zig`,
`build.zig.zon`, `src/main.zig`, `src/root.zig`; `zig init -m` for minimal)
with `run_cmd.addPassthruArgs()` and `minimum_zig_version = "0.17.0"`. Its
comments still mention the old optimize names; ignore them.

**Unchanged in 0.17:** `standardTargetOptions`, `standardOptimizeOption`,
`b.option`, `createModule`/`addModule`, `addExecutable`/`addLibrary`/`addTest`/
`addObject` with `.root_module`, `addRunArtifact`, `addSystemCommand`,
`installArtifact`, `addInstallArtifact`, `addInstallFile`,
`addInstallDirectory`, `addWriteFiles`, `b.path`, `b.step`, `getInstallStep`,
`b.addOptions`, `b.dependency(name, args)` (now also handles `.lazy = true`
deps), and the Module methods `linkSystemLibrary`, `linkFramework`,
`addCSourceFiles`, `addIncludePath`, `addCMacro`, `addConfigHeader`,
`linkLibrary`, `addImport`, `addOptions`. Install somewhere custom with
`b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "../bin" } } })`.
Build-time file access uses `b.graph.io` (`std.Io.Dir.cwd().access(b.graph.io, p, .{})`).

### 20.3 API changes (0.16 → 0.17)

| 0.16 | 0.17 | Status |
|---|---|---|
| `b.args` + `run.addArgs(args)` | `run.addPassthruArgs()` | removed |
| `optimize == .Debug` (`!=`, `orelse`) | `.debug` / `.safe` / `.fast` / `.small` | removed |
| `b.build_root` (`.path`, `.handle`) | `b.root` (`Cache.Path`; `b.fmt("{f}", .{b.root})`, `b.root.join(…)`) | removed |
| `b.pathFromRoot(p)` | `b.path(p)` | removed |
| `b.install_path`, `install_prefix`, `exe_dir`, `lib_dir`, `h_dir`, `dest_dir` | `b.graph.path(.install_prefix / .install_bin / .install_lib / .install_include, "sub")` → `LazyPath` (step inputs only) | removed |
| `b.getInstallPath(dir, sub)` | pass `exe.getEmittedBin()` / a `LazyPath` to the consuming step | removed |
| `b.cache_root` | `std.Build.LazyPath.cache_root` | removed |
| `b.verbose*`, `b.release_mode`, `b.search_prefixes` | `b.graph.verbose`, `b.graph.release_mode`, `b.graph.search_prefixes` | moved |
| `b.sysroot`, `libc_file`, `build_id`, `enable_qemu`/`wine`/`wasmtime`/`rosetta`/`darling`, `debug_*`, `pkg_config_pkg_list` | removed (third-party runners: `run.addThirdPartyEnabledArg{Qemu,Wine,…}`) | removed |
| `b.graph.zig_lib_directory`, `global_cache_root`, `cache`, `incremental`, `random_seed`, `max_jobs` | removed; `b.graph.zig_exe` is `[]const u8` | removed |
| `lazy_path.getPath(b)` / `getPath2/3/4` | none: resolve paths inside a step (pass the `LazyPath` to a Run step) | removed |
| `lazy_path.basename()` | removed (unknown until make time) | removed |
| `lazy_path.getDisplayName()` | `"{f}"` (debug output only; prints the base tag) | deprecated |
| Custom step: `Step.init(.{ .id = .custom, .makeFn = f })`, `Step.MakeOptions`, `step.make`, `fail`, `evalZigProcess`, `addWatchInput` | **no replacement**: write the logic as a Zig program, `b.addExecutable(… .target = b.graph.host …)`, run it with `b.addRunArtifact` | removed |
| `Step.Id`, `step.id`, `T.base_id` | `Step.Tag`, `step.tag`, `T.base_tag` (`.objcopy` → `.obj_copy`) | renamed |
| `compile.setExecCmd(…)` | add the arguments to the Run step | removed |
| `compile.checkObject()` / `Step.CheckObject` | removed (moved into the maker) | removed |
| `compile.getEmittedCompilerRtDynLib`, `runPkgConfig` | removed | removed |
| `compile.entitlements: ?[]const u8` | `?LazyPath` | changed |
| `run.addPathDir` | removed | removed |
| `run.enableTestRunnerMode()` | `run.enableProtocolMode()` | deprecated |
| `run.addArtifactArg`, `addPrefixedArtifactArg` | `run.addArtifactArg2(exe, .{ .prefix, .suffix, .make_absolute })` | deprecated |
| `addOutputFileArg`, `addPrefixedOutputFileArg` | `addOutputFileArg2(name, .{ … })` | deprecated |
| `addFileArg`, `addPrefixedFileArg` | `addFileArg2(lp, .{ … })` | deprecated |
| `addDirectoryArg`, `addPrefixedDirectoryArg`, `addDecoratedDirectoryArg` | `addDirectoryArg2` | deprecated |
| `addOutputDirectoryArg*`, `addFileContentArg*`, `addDepFileOutputArg*` | `…Arg2` | deprecated |
| Run path args were absolute | **relative** (`./build.zig`); `.make_absolute = true` restores | silent |
| `options.addOptionPath(name, lp)` | file only (value now relative); `addOptionPathDirectory` for dirs; `addOptionPathUntracked` | changed |
| `b.addFmt(.{ .paths = &.{"src"} })` | `.paths = b.pathList(&.{"src"})` (and `exclude_paths`) | changed |
| `b.addConfigHeader(.{ .include_guard_override = … })` | `.include_guard` | renamed |
| `b.findProgram(names, paths) error{FileNotFound}![]const u8` | `b.findProgram(.{ .names = &.{…} }) ?[]const u8` — **poisons the configure cache** | changed |
| — | `b.findProgramLazy(.{ .names = &.{…} })` → `LazyPath` resolved at make time (no poisoning) | new |
| `b.lazyDependency(name, args)` → `?*Dependency` | `try b.dependencyLazy(name, args)` in `pub fn build(b: *std.Build) !void` (returns `error.LazyDependencyNeeded`, which the build system handles by fetching) | deprecated |
| `b.runAllowFail(argv, …)` | `b.runFallible(argv, .{})` → `RunResult` | deprecated |
| `b.dupe`, `dupeStrings`, `dupePath` → `[]u8` | return `[]const u8`; prefer `b.graph.dupeString` | changed |
| `b.addTranslateC(.{ .root_source_file })` + `.createModule()` | works (deprecated); prefer the `translate_c` package (§20.6) | deprecated |
| `Module.addWin32ResourceFile`, `Compile.win32_manifest` | deprecated (moving to an external package) | deprecated |
| `exe.subsystem = .Windows`; `std.Target.SubSystem` | `.windows`; `std.zig.Subsystem` | removed |
| `std.Build.Watch`, `Fuzz`, `WebServer` | moved into `lib/compiler/Maker` (not public) | removed |
| — | `b.addRunFile(lp)`, `b.pathList`, `b.isRoot()`, `b.dependOnFileContents/FileMetadata/DirectoryContents/DirectoryMetadata`, `b.graph.poisonCache()`, `std.Build.Configuration`, `Module.CreateOptions.patchable_function_entry`, `compile.incremental` | new |

### 20.4 Configure-cache rules (0.17)

- Keep `build()` **pure**: depend only on `build.zig`, `-D` options and
  declared inputs. Then the configurer is skipped entirely on repeat builds.
- If configuration reads a file or directory, declare it:
  `b.dependOnFileContents(path)`, `dependOnFileMetadata`,
  `dependOnDirectoryContents`, `dependOnDirectoryMetadata`.
- `b.findProgram` and `b.graph.poisonCache()` mark the configuration
  uncacheable (re-run every time). Prefer `findProgramLazy`.
- `b.run(argv)` does **not** poison the cache: its result is frozen until
  `build.zig` changes.
- **Probing the filesystem in `build()`** (looking for a sibling tool, say)
  is frozen with the configuration: a tool built later is never noticed.
  Declare what was found, and poison the cache when nothing was:
  ```zig
  std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch { b.graph.poisonCache(); return null; };
  b.dependOnFileMetadata(.{ .cwd_relative = path });
  ```
- **A dependency on a file that does not exist fails the configuration**
  (`error: configuration failed: FileSystemFailure`, no file named), though
  the doc comments promise a re-run on creation. To notice a file appearing,
  depend on its directory: `b.dependOnDirectoryContents(b.path(dirname))`.
- **`build()` cannot see the install prefix** (`-p`). To keep a binary in
  the checkout (`bin/tool`) and still honor `-p`, copy it into the source
  tree as well as installing it (the executable bit is kept):
  ```zig
  const to_checkout = b.addUpdateSourceFiles();
  to_checkout.addCopyFileToSource(exe.getEmittedBin(), "bin/tool");
  b.getInstallStep().dependOn(&to_checkout.step);
  b.installArtifact(exe); // PREFIX/bin/tool, zig-out/bin/tool without -p
  ```
  When scripts build release copies elsewhere with `-p` and `bin/tool` must
  stay as it is, make the copy the default step instead, and have those
  scripts run `zig build install -p DIR`:
  ```zig
  const bin = b.step("bin", "Build bin/tool in the checkout (the default)");
  bin.dependOn(&to_checkout.step);
  b.default_step = bin; // `zig build` → bin/tool; `zig build install -p DIR` → DIR/bin/tool only
  ```
- `--cache-poison=pure` (default) / `poisoned` (never cache) / `disallowed`
  (panic when poisoned; good for CI) / `ignored`.
- Debug configuration: `zig build --print-configuration` (ZON dump of the
  graph), `--print-configuration-path`; `zig cache-cat <manifest>` explains
  cache entries.

### 20.5 Package management

- `zig fetch --save <url>` writes `build.zig.zon`; fetched packages land in
  `./zig-pkg/` (add it to `.gitignore`) and are re-tarballed into the global
  cache. Without `--save`, `zig fetch` fills only the global cache; `zig
  fetch .` works again.
- `--pkg-dir PATH` / `ZIG_LOCAL_PKG_DIR` override the local package dir for
  `fetch` and `build`. **The release notes say `--pkg-path`; the real flag is
  `--pkg-dir`.**
- `zig build --fork=PATH` (or `--fork PATH`) replaces every package in the
  tree whose `name`+`fingerprint` match the `build.zig.zon` at PATH.
- Path dependencies may not escape the parent package root (0.17).
- A transitive dependency's `build.zig` must also compile on 0.17, or your
  build stops before your code is compiled. Pin 0.17-compatible commits;
  vendor or fork if needed; never "fix" files inside `zig-pkg/` or the global
  cache.

### 20.6 C headers: `@cImport` is gone

```bash
zig fetch --save git+https://codeberg.org/ziglang/translate-c
```

```zig
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.dependency("translate_c", .{});
    const translator: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),            // a header that #includes what you need
        .target = target,
        .optimize = optimize,
    });
    translator.linkSystemLibrary("glfw3", .{});

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "c", .module = translator.mod }},
        }),
    });
    b.installArtifact(exe);
}
// src/main.zig:  const c = @import("c");
```

`Translator.Options`: `name`, `c_source_file`, `target`, `optimize`,
`link_libc`, `link_system_libs`, `warnings`, `module_libs`, `pub_static`,
`func_bodies`, `keep_macro_literals`, `default_init`, `strict_flex_arrays`,
`libc_file`, `extra_args`. Methods: `linkLibrary`, `addObject`,
`addIncludePath`, `addSystemIncludePath`, `addFrameworkPath`,
`addConfigHeader`, `defineCMacro`, `linkSystemLibrary`. Fields: `mod`,
`output_file`, `run`. (Verified with 0.17.0 against translate-c commit
875969d; the package declares `minimum_zig_version = "0.18.0-dev.1"` but that
is not enforced.)

The quick path (deprecated, still works, no network needed):

```zig
const tc = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
mod.addImport("c", tc.createModule());
```

Translate-C is implemented with Aro, not libclang. `zig translate-c` and `zig
rc` remain as CLI subcommands.

### 20.7 CLI flags

| Change | Detail |
|---|---|
| optimize names | `-Doptimize=fast` / `-O fast` (`debug`, `safe`, `fast`, `small`); old names still accepted there; `--release=` accepts only `off\|any\|fast\|safe\|small` |
| removed from `zig build` | `--global-cache-dir` (use `ZIG_GLOBAL_CACHE_DIR`), `--zig-lib-dir` (now `--zig-lib=PATH`, must be the **first** argument), `--build-runner`, `--verbose-llvm-bc=`; `ZIG_BUILD_RUNNER` env |
| removed from `build-exe`/`test` | `-f[no-]formatted-panics`, `-f[no-]structured-cfg` |
| new on `zig build` | `--listen=-`, `--cache-poison=…`, `--print-configuration`, `--print-configuration-path`, `--error-limit`, `--pkg-dir` |
| new subcommands/flags | `zig cache-cat`, `zig objdump` (real options), `zig fmt --complexity` (token/AST-node counts), `--build-root`, `-fpatchable-function-entry=`, `--growable-table` |
| `zig fetch` | `--global-cache-dir` removed; `--cache-dir`, `--pkg-dir`, `--debug-log` added |
| new env vars | `ZIG_LOCAL_PKG_DIR`, `ZIG_BUILD_SUMMARY`, `ZIG_VERBOSE_CMD`, `ZIG_DEBUG_CMD` (compile the build system in Debug), `PKG_CONFIG` |
| from 0.16, still valid | `--error-style verbose\|minimal\|verbose_clear\|minimal_clear`, `--multiline-errors indent\|newline\|none`, `--test-timeout 500ms`, `--fork`, `-fincremental --watch`, `--summary all` |
| `libc.txt` | `gcc_dir` renamed `cc_dir` (old name still accepted); `cc_dir` required on Linux |
| `zig cc` (Clang 22) | rejects `-mevex512` (*unknown clang option*): `evex512` is folded into `avx512f`, so drop the flag from C build scripts |

Every `build.zig` compile error now ends with `referenced by: runPackageScript
… lib/compiler/configurer.zig`; that frame is the configurer, not your bug.

---

## 21. Compiler, linker, toolchain, targets

- **Incremental compilation:** `zig build -fincremental --watch` works for
  most `x86_64-linux` projects (the new ELF linker supports it). On
  aarch64-macos it currently **crashes** (*panic: TODO(MachO2): load
  archive*); don't use it there yet.
- **New ELF linker:** default with `-fincremental` on ELF; still not the
  default otherwise. Gained static/shared library output, DWARF, GOT, copy
  relocations, symbol versioning. `-fnew-linker` / `exe.use_new_linker = true`.
- **COFF linker** much more complete (objects, archives, import libs, TLS,
  `.drectve` handling); **SPIR-V linker** rewritten; new `zig objdump` and
  snapshot-based linker tests.
- **Backends:** x86_64 self-hosted (Debug default on several x86_64 OSes);
  aarch64 self-hosted still not usable; wasm self-hosted passes 100% of
  behaviour tests but is not yet the Debug default; experimental loongarch64;
  SPIR-V backend multithreaded, with execution modes derived from calling
  conventions (`spirv_fragment`, `spirv_kernel`, `spirv_task`, `spirv_mesh`
  carry payloads) and capabilities from `-mcpu` features (no more
  `OpCapability` inline asm).
- **New calling conventions:** `x86_64_preserve_none`, `aarch64_preserve_none`,
  `x86_mingw`, `m88k_sysv`, `ez80_cet`, `ez80_tiflags`, `spork8`.
- **Grammar:** the formal PEG grammar now matches the parser and is fuzzed.
- **Targets:** `loongarch32-linux` added; usable `sparc64-linux`; std ported
  to x32 and MIPS N32; stack traces on 32-bit ARM and SPARC; much better
  native CPU detection; `powerpc-linux-gnueabi[hf]` and `powerpc64-linux-gnu`
  dropped; new baseline CPUs on several arches (e.g. `powerpc64-linux` →
  `pwr8`, `s390x` → `arch11`). Target queries detect native libc version only
  when the ABI component is omitted. `std.Target.parseCpuModel` returns an
  optional; `cTypeByteSize`/`cTypeBitSize`/… return optionals;
  `Arch.isAARCH64`/`isRISCV`/`isMIPS*`/`isPowerPC*`/`isSPARC`/`isSpirV`/
  `isLoongArch` → `isAarch64`/`isRiscv`/`isMips*`/`isPowerpc*`/`isSparc`/
  `isSpirv`/`isLoongarch` (old spellings deprecated); `Os.Tag.isBSD()`
  deprecated.
- **Only `x86_64-linux` is Tier 1.** aarch64-macos, aarch64-linux,
  x86_64-windows etc. are Tier 2. `x86_64-macos` is now marked obsolescent.
- **zig libc** provides more functions for static musl, MinGW-w64 and WASI;
  report libc bugs to Zig, not upstream. WASI libc will be replaced by zig
  libc in 0.18.

---

## 22. Compile-error decoder

Error text → cause → fix. Grouped by area; "0.17" marks messages new in
0.17. Fragments are verbatim from the 0.17.0 compiler unless marked (0.16).

### 22.1 Language

| Error fragment | Cause | Fix |
|---|---|---|
| `binary operator '*' has whitespace on one side, but not the other` | `x ** n` array repetition (0.17) | `@splat` |
| `expected type 'type', found 'comptime_int'` on `[_]u8{0}**16` | unspaced `**` (0.17) | `@splat` |
| `expected block or expression, found '\|'` | `errdefer \|err\|` (0.17) | catch at call site |
| `type 'void' does not support array initialization syntax` | `void{}` (0.17) | `{}` |
| `signed integer cannot have bit width 0` | `i0` (0.17) | `u0` |
| `no field named 'Debug' in enum 'lang.Optimize'` | `== .Debug` etc. (0.17) | `.debug`/`.safe`/`.fast`/`.small` |
| `enum 'lang.GlobalLinkage' has no member named 'internal'` | removed linkage (0.17) | don't `@export`; `.weak` for `link_once` |
| `cannot @bitCast from 'T'` + `note: struct declared here` | `@bitCast` of `extern struct`/`union` (0.17) | `@ptrCast`, `std.mem.bytesToValue`, `extern union` |
| `@backingInt is ambiguous for type 'PS'` | packed struct with inferred backing int (0.17) | `packed struct(uN)` or keep `@bitCast` |
| `expected type 'u8', found 'usize'` at `@fromBackingInt` | runtime arg not exactly the backing type (0.17) | `@fromBackingInt(@intCast(x))` |
| `empty exhaustive enums must be backed by 'noreturn'` | `enum(u8) {}` (0.17) | `enum {}` |
| `invalid builtin function: '@cImport'` | (0.17) | §20.6 |
| `no field named 'fields' in struct 'lang.Type.Struct'` (also `'decls'`, Enum `'is_exhaustive'`, Union `'fields'`, Fn `'params'`, Pointer `'is_const'`/`'alignment'`) | reflection SoA (0.17) | §6.2 |
| `expected optional type, found 'lang.Type.ErrorSet'` | `error_set.?` (0.17) | `error_set.error_names.?` |
| `union 'lang.Type' has no member named 'StructField'` (UnionField, EnumField, Declaration, Error); `struct 'lang.Type.Fn' has no member named 'Param'` | removed types (0.17) | `Type.Struct.FieldAttributes` etc. |
| `deprecated in favor of @typeInfo` / `deprecated in favor of @hasDecl` | `std.meta.fields` / `declarationInfo` (0.17) | `@typeInfo` / `@hasDecl` |
| `root source file struct 'meta' has no member named 'Int'` (`'Tuple'`) | (0.17) | `@Int` / `@Tuple` |
| `unable to resolve comptime value` + `inline loop condition must be comptime-known` | `inline for (std.meta.fieldNames(T))` (0.17 returns a slice) | `inline for (comptime std.meta.fieldNames(T))` |
| `invalid builtin function: '@Type'` | (0.16) | `@Int`, `@Struct`, … |
| `pointer not allowed in packed struct` / `packed structs cannot contain fields of type '*u8'` | (0.16) | `usize` + `@ptrFromInt` |
| `field bit width does not match earlier field` | packed union field sizes differ (0.16) | equal-width fields / explicit backing |
| `integer tag type of enum is inferred` (extern context) | (0.16) | `enum(u8)` |
| `returning address of expired local variable 'x'` | (0.16) | return by value or allocate |
| `vector index not comptime known` | runtime vector index (0.16) | coerce to an array |
| `documentation comments cannot be attached to tests` | `///` before `test` (0.16) | `//` |
| `dependency loop with length N` | type-resolution cycle (0.16) | read the numbered notes; break one link |
| `lossy conversion from comptime_int to f32` | (0.15) | float literal or `@floatFromInt` |
| `local variable is never mutated` / `unused local constant` | | `const` / `_ = x;` |

### 22.2 Standard library

| Error fragment | Cause | Fix |
|---|---|---|
| `root source file struct 'fs' has no member named 'cwd'` | (0.16) | `std.Io.Dir.cwd()` + `io` |
| `root source file struct 'std' has no member named 'io'` | `std.io.getStdOut`, `fixedBufferStream` (0.16) | `std.Io.File.stdout()`, `std.Io.Writer.fixed` |
| `member function expected 1 argument(s), found 0` on `close`/`stat`/… | missing `io` (0.16) | `file.close(io)` |
| `no field or member function named 'writeAll' in 'Io.File'` | (0.16) | `file.writeStreamingAll(io, bytes)` |
| `expected type 'Io.Limit', found 'comptime_int'` | bare size cap (0.16) | `.limited(n)` |
| `type 'Io.Writer' not a function` / `tried to invoke non-function` | `out.writer()` on `Writer.Allocating` (0.16) | `&out.writer`, `out.writer.print` |
| `missing struct field: items` | `ArrayList` from `.{}` (0.16) | `.empty` |
| `missing struct field: pointer_stability` | `ArrayList` struct literal (0.17) | `.empty` / `.initBuffer` / `.initCapacity` |
| `member function expected 2 argument(s), found 1` on `append`/`deinit` | unmanaged container without allocator | pass `gpa` |
| `no field or member function named 'writer'` on an `ArrayList` | (0.15) | `list.print(gpa, …)` or `Writer.Allocating` |
| `root source file struct 'mem' has no member named 'trimLeft'` | (0.16) | `trimStart` / `trimEnd` |
| `root source file struct 'heap' has no member named 'GeneralPurposeAllocator'` | (0.16) | `SafeAllocator` |
| `root source file struct 'heap' has no member named 'stackFallback'` (or `'StackFallbackAllocator'`) | (0.17) | `std.heap.BufferFirstAllocator` |
| `incompatible types: 'usize' and '@EnumLiteral()'` | `sa.deinit() == .leak` (0.17) | `sa.deinit() != 0` |
| `root source file struct 'fmt' has no member named 'bufPrintZ'` | (0.17) | `std.mem.printSentinel(&buf, …, 0)` |
| `no field or member function named 'dupeZ' in 'mem.Allocator'` | (0.17) | `dupeSentinel(u8, s, 0)` |
| `struct 'bit_set.Integer(8)' has no member named 'initEmpty'` (`EnumSet` too) | (0.17) | `.empty` / `.full` |
| `root source file struct 'mem' has no member named 'containsAtLeastScalar2'` | (0.17) | `containsAtLeastScalar(T, s, elem, min)` |
| `root source file struct 'ascii' has no member named 'indexOfIgnoreCase'` | (0.17) | `findIgnoreCase` |
| `root source file struct 'mem' has no member named 'readPackedIntNative'` | (0.17) | `readPackedInt(…, endian)` |
| `byteSwapAligned expects a packed or extern struct` | (0.17) | only swap extern/packed structs |
| `member function expected 2 argument(s), found 3` on `setKey` | (0.17) | `map.setKey(i, k)` |
| `root source file struct 'zon' has no member named 'fromSlice'` | (0.17) | `std.zon.parse.fromSlice(T, .{…})` |
| `root source file struct 'zon.parse' has no member named 'fromSliceAlloc'` / `expected 2 argument(s), found 5` | (0.17) | §17.1 |
| `missing struct field: errors` | `Diagnostics = .{}` (0.17) | `= undefined` |
| `root source file struct 'heap' has no member named 'MemoryPoolExtra'`; `'heap.memory_pool' has no member named 'Managed'` | (0.17) | `std.heap.MemoryPool(T)`, `memory_pool.Extra` |
| `root source file struct 'hash.crc' has no member named 'Crc32Iscsi'` | (0.17) | `std.hash.crc.@"CRC-32/ISCSI"`; `Crc` → `Generic` |
| `root source file struct 'std' has no member named 'gpu'` | (0.17) | `std.spirv` |
| `root source file struct 'Io.File' has no member named 'OpenFlags'` (`CreateFlags`, `OpenMode`) | (0.17) | `std.Io.Dir.OpenFileOptions` etc. |
| `root source file struct 'process' has no member named 'spawnPath'` (`replacePath`) | (0.17) | `.exe = .{ .path = dir }` |
| `no field named 'disable_aslr' in struct 'process.SpawnOptions'` | (0.17) | delete it |
| `This function has been moved to std.Io.net.HostName.fromUri` | `Uri.getHost` (0.17) | `HostName.fromUri(uri, &buf)` |
| `'std.lang.panic' missing 'unexpectedErrorCode'` (`'loadUninstantiableType'`) | custom panic namespace (0.17) | §19.2 |
| `'error.Timeout' not a member of destination error set` | `net.Stream.Reader.Error` (0.17) | drop the prong; handle `ConnectionTimedOut` |
| `unhandled error value: 'error.ConnectionTimedOut'` / `unhandled enumeration value: 'QUERY'` | grown error sets / `http.Method` (0.17) | add prongs |
| `expected type 'bool', found '?bool'` | `ip6_only` (0.17) | `orelse false` |
| `type 'Io.net.Stream.ReadResult' cannot be destructured` (inside std) | std bug in `Stream.read` (0.17.0) | `readWithControl` or `stream.reader` |
| `expected error union type, found '?*const Target.Cpu.Model'` | `parseCpuModel` (0.17) | handle the optional |
| `error: not testing` | `std.testing.allocator` outside tests | use another allocator |
| `cannot format slice without a specifier (i.e. {s}, {x}, {b64}, or {any})` | `{}` on a string | `{s}` |
| `cannot print optional without a specifier (i.e. {?} or {any})` | `{}` on `?T` | `{?}` |
| `member function expected 3 argument(s), found 1` from `{f}` | 0.14-style `format(self, fmt, opts, w)` | `format(self, w: *std.Io.Writer)` |
| `error.OutOfMemory` at run time from `spawn`/networking with free memory | `global_single_threaded` Io | pass `init.io` |
| `error(SafeAllocator): leaked [addr: …, len: …] allocated at:` (a program), `[SafeAllocator] (err): leaked …` (the test runner) (0.17; 0.16: `error(DebugAllocator): memory address … leaked`) | a leak under `init.gpa`/`testing.allocator`/a `SafeAllocator` | free it or use an arena |
| `expected type '*i32', found '*u32'` at `std.os.linux.waitpid` | the status out-parameter is `*i32` (0.17) | `var status: i32 = 0;` |

### 22.3 Build system (all 0.17)

| Error fragment | Fix |
|---|---|
| `no field named 'args' in struct 'Build'` | `run_cmd.addPassthruArgs()` |
| `no field named 'build_root' in struct 'Build'` | `b.root` |
| `no field named 'install_path'` / `'install_prefix'` / `'cache_root'` / `'verbose'` / `'sysroot'` / `'release_mode'` / `'enable_qemu'` in struct `'Build'` | §20.3 |
| `no field or member function named 'getInstallPath'` / `'pathFromRoot'` in `'Build'` | `LazyPath`s / `b.path` |
| `no field or member function named 'getPath'` (`'basename'`) in `'Build.LazyPath'` | pass the `LazyPath` to a step |
| `expected type 'Build.LazyPath', found '*const [3:0]u8'` (in `addFmt`) | `b.pathList(&.{…})` |
| `no field named 'id' in struct 'Build.Step.StepOptions'` / `root source file struct 'Build.Step' has no member named 'MakeOptions'` | custom step → tool exe + `addRunArtifact` |
| `no field named 'id' in struct 'Build.Step'` | `step.tag` |
| `no field or member function named 'setExecCmd'` / `'checkObject'` in `'Build.Step.Compile'` | args on the Run step / removed |
| `no field or member function named 'addPathDir' in 'Build.Step.Run'` | removed |
| `no field named 'include_guard_override' in struct 'Build.Step.ConfigHeader.Options'` | `.include_guard` |
| `member function expected 1 argument(s), found 2` on `findProgram` | `b.findProgram(.{ .names = &.{…} })` (returns `?[]const u8`) |
| `enum 'zig.Subsystem' has no member named 'Windows'`; `root source file struct 'Target' has no member named 'SubSystem'` | `.windows`; `std.zig.Subsystem` |
| `no field named 'zig_lib_directory'` / `'global_cache_root'` in struct `'Build.Graph'` | removed |
| `cannot assign to constant` on the result of `b.dupe` | it returns `[]const u8` now |
| `checking cache failed: file_read IsDir …` (make time) | `addOptionPath` on a directory → `addOptionPathDirectory` |
| `expected -Doptimize to be of type "lang.Optimize"` | `-Doptimize=fast` (not `Fast`/`release-fast`) |
| `expected --release=[off\|any\|fast\|safe\|small]` | `--release=fast` |
| `unrecognized argument: --global-cache-dir` (`--zig-lib-dir`, `--build-runner`) | `ZIG_GLOBAL_CACHE_DIR=…`, `--zig-lib=…` first |
| `invalid fingerprint: 0x0; if this is a new or forked package, use this value: 0x…` | paste the suggested value into `.fingerprint` |

---

## 23. Migration playbook and grep sweep

### 23.1 Order of work

1. **Baseline.** `zig version` (0.17.0); `zig build 2>&1 | tee
   /tmp/zig017-baseline.log`. Errors arrive one at a time; this is a probe,
   not a census. Record pre-existing test failures. Note the Debug wall time
   of a representative workload.
2. **Dependencies.** Each dependency's `build.zig` must compile on 0.17.
   Update pins to 0.17-compatible commits, or vendor/fork.
3. **`build.zig`.** In order: optimize names → `b.args` → `addFmt` paths →
   `build_root`/install paths/`getPath` → custom steps → `findProgram` →
   `@cImport`/translate-C → deprecated `*Arg` helpers (optional). Bump
   `minimum_zig_version`.
4. **Unparseable syntax first** (so `zig fmt` can run): `**` repetition,
   `errdefer |err|`. Then `zig fmt` the touched files to auto-upgrade
   `@intFromEnum`/`@enumFromInt`. Format narrowly; a repo-wide `zig fmt` can
   produce unrelated churn — review that separately. Leave checked-in
   generated files out of `zig fmt` and `zig fmt --check`: they are
   regenerated, not hand-formatted.
5. **Source, one API family at a time, compiling between each:** optimize
   mode / `std.builtin` → reflection (`@typeInfo`, `std.meta`) → allocators
   (`SafeAllocator`, `allocPrint`, `bufPrint*`, `dupeZ`, `stackFallback`) →
   containers (`getLast`, bit sets, `setKey`, `MemoryPool`) → ZON → process /
   net / http signatures → panic handler → stragglers.
6. **Silent traps by hand** (§4.1): `containsAtLeastScalar`, `@hasDecl`
   on private decls, relative Run path args, configure caching, BE
   `@bitCast`, `@tagName(builtin.mode)`.
7. **Gates that really run.** Re-run the suite with a fresh `--cache-dir`
   before calling it green; an unchanged tree replays cached results
   (§4.1.17).
8. **Every target and mode.** Compile each published target (WASM and
   freestanding separately: a native build hides target-only breakage) and
   `-Doptimize=safe|fast`. Use `-freference-trace=20` to find why host-only
   code is reachable.
9. **Test with a real workload** in Debug and compare with the baseline,
   then run the release benchmarks A/B against the 0.16 build (§23.7).
10. **Sweep** (§23.2) and update CI images, README and contributor docs to
    0.17.0.

### 23.2 Grep sweep (should all be empty, or every hit reviewed)

```bash
# 0.17 hard breaks
rg -n --type zig '\}\s*\*\*\s|"\s*\*\*\s' .                              # array repetition (ignore glob strings)
rg -n --type zig 'errdefer\s*\|' .
rg -n --type zig 'void\{\}|\bi0\b|\.link_once|\.internal\b' .
rg -n --type zig '\.(Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)\b' .   # mode comparisons (switch prongs still compile)
rg -n --type zig '@cImport|@cInclude|@cDefine' .
rg -n --type zig '\.@"(struct|union|enum|opaque)"\.(fields|decls)|\.is_exhaustive|\.params\b|\.calling_convention|\.is_var_args' .
rg -n --type zig 'std\.meta\.(fields|declarationInfo|Int|Tuple)\b|meta\.fieldNames\(' .
rg -n --type zig 'stackFallback|StackFallbackAllocator|bufPrintZ|\.dupeZ\(|initEmpty\(\)|initFull\(\)' .
rg -n --type zig 'containsAtLeastScalar2|readPackedInt(Native|Foreign)|writePackedInt(Native|Foreign)|indexOfIgnoreCase' .
rg -n --type zig 'std\.zon\.(parse\.)?fromSlice|fromSliceAlloc|zon\.parse\.free' .
rg -n --type zig 'std\.gpu\b|Target\.SubSystem|\.subsystem\s*=\s*\.[A-Z]' .
rg -n --type zig 'OpenFlags|CreateFlags|File\.OpenMode|spawnPath|replacePath|disable_aslr|getHost(Alloc)?\(' .
rg -n --type zig '\.leak\b|== \.ok\b' .                                  # old DebugAllocator deinit checks
rg -n 'b\.args|build_root|install_path|install_prefix|getInstallPath|pathFromRoot|\.getPath[0-9]?\(|makeFn|setExecCmd|checkObject|findProgram\(&|include_guard_override' --glob '*.zig' .
rg -n -- '--global-cache-dir|--zig-lib-dir|--build-runner|-Drelease|-Doptimize=Release|--release=Release' .

# 0.17 deprecations (compile today, migrate anyway)
rg -n --type zig '@intFromEnum|@enumFromInt|std\.builtin\.|(builtin|@import\("builtin"\))\.(cpu|os|abi|object_format|mode)\b' .
rg -n --type zig 'fmt\.allocPrint|fmt\.bufPrint|DebugAllocator|heap\.Check\b|getLast(OrNull)?\(' .
rg -n --type zig 'IntegerBitSet|ArrayBitSet|StaticBitSet|DynamicBitSet|ArrayListUnmanaged|ArrayHashMapUnmanaged|lazyDependency|runAllowFail|addTranslateC|(Artifact|OutputFile|FileContent|OutputDirectory|Directory|DepFileOutput|File)Arg\(' .
rg -n --type zig 'std\.mem\.(indexOf|lastIndexOf)|@intFromFloat|byteSwapAllFields|runtime_safety|std\.fs\.|array_list\.Managed' .

# 0.17 silent traps — review every hit
rg -n --type zig 'containsAtLeastScalar\(' .
rg -n --type zig '@hasDecl' .
rg -n --type zig '@bitCast' .                    # extern structs, arrays/vectors on BE targets
rg -n --type zig '@tagName\((@import\("builtin"\)|builtin)\.(mode|optimize)\)' .

# 0.15/0.16 leftovers
rg -n --type zig 'std\.fs\.(cwd|File|Dir|openFile|createFile)|std\.io\.|std\.net\.|std\.time\.(timestamp|milliTimestamp|nanoTimestamp|Timer|Instant)|std\.Thread\.(Mutex|Condition|Pool|ResetEvent|WaitGroup|Futex|sleep)' .
rg -n --type zig 'GeneralPurposeAllocator|ThreadSafeAllocator|argsAlloc|std\.os\.environ|crypto\.random|trimLeft|trimRight|@Type\(|usingnamespace' .
rg -n --type zig '= \.\{\}' .                    # container init → .empty (review: plain structs are fine)
```

### 23.3 Sed for the mechanical ones (review the diff after each)

```bash
# optimize-mode tag comparisons (also catches switch prongs; harmless)
sed -i '' -E 's/\.Debug\b/.debug/g; s/\.ReleaseSafe\b/.safe/g; s/\.ReleaseFast\b/.fast/g; s/\.ReleaseSmall\b/.small/g' FILES
# allocPrint / bufPrint
sed -i '' -E 's/std\.fmt\.allocPrint\(([a-zA-Z_.]+), /\1.print(/g; s/std\.fmt\.bufPrint\(/std.mem.print(/g' FILES
# getLast
sed -i '' -E 's/\.getLastOrNull\(\)/.last()/g; s/\.getLast\(\)/.last().?/g' FILES
# std.builtin → std.lang
sed -i '' -E 's/std\.builtin\./std.lang./g' FILES
```

(GNU sed: drop the `''` after `-i`.) Do **not** sed `@intFromEnum`/
`@enumFromInt`; `zig fmt` does it correctly. Do **not** sed
`containsAtLeastScalar`; swap arguments by hand.

### 23.4 Done when

- `zig build` and `zig build test` are green on 0.17.0 with no new warnings.
- Every published target and optimize mode builds.
- `zig fmt --check` passes on touched files.
- The §23.2 hard-break and trap sweeps are empty or every hit reviewed.
- A representative Debug workload shows no order-of-magnitude slowdown.
- `git diff` contains only intended migrations; CI and docs name 0.17.0.
- The project's own docs are current: `AGENTS.md`/`README` name Zig 0.17 and
  link this guide, notes written for an older Zig are deleted, benchmark
  records hold the 0.17 numbers, and a handoff or state document (if the
  project keeps one) describes where the work stands, in present tense.

### 23.5 Code generators and self-hosting projects

Lessons from porting a parser generator whose output is compiled by other
projects and whose own frontend is generated by itself.

1. **Fix the emitter, never the output.** Generated files are build
   artifacts. Change the templates and emitter code, regenerate, then review
   the regenerated goldens.
2. **`zig fmt` never sees code inside strings.** Multiline `\\` string
   templates and `w.print("…")` format strings that *contain* Zig are invisible
   to the formatter and to the compiler until the output is compiled. Grep the
   emitter sources for old forms inside strings: `**`, `.fields`, `.decls`,
   `@intFromEnum`, `@enumFromInt`, `getLast`, `ArrayListUnmanaged`,
   `allocPrint`, `runtime_safety`, `enum(u16) {}`. A template kept as a real,
   compiled `.zig` file (embedded with `@embedFile` and cut into sections) is
   upgraded by `zig fmt` like any other source: prefer that design.
3. **Bootstrap a self-hosted generator.** When the generator's own source
   includes code it generated (a frontend parser, tables), 0.17 cannot build
   it until it is regenerated, and it cannot be regenerated without building
   it. Recipe:
   ```bash
   # 1. fix the emitter templates (step 2)
   git show HEAD:build.zig > build16.zig                  # the pre-port build script
   zig-0.16 build --build-file build16.zig && rm build16.zig
   ./bin/tool its.grammar src/frontend/parser.zig         # regenerate with the emitter fix
   zig build                                              # now with 0.17
   ./bin/tool its.grammar src/frontend/parser.zig && zig build   # repeat until the output is a fixed point
   ```
   After the first 0.17 build, every later emitter change follows the plain
   loop: build, regenerate, build, regenerate (until no diff).
4. **Generated bytes change with std.** `std.zig.fmtString` passes valid UTF-8
   through, so emitted literals change from `"\xe2\x86\x92"` to `"→"`. Golden
   tests fail on that alone; regenerate them.
5. **Review regenerated goldens by kind, not by line.** Normalise numbers and
   names, then count distinct changed lines; every bucket must be a planned
   rewrite:
   ```bash
   git diff -U0 test/golden | grep -E '^[-+][^-+]' | sed -E 's/^([-+])\s+/\1 /; s/[0-9]+/N/g; s/"[^"]*"/"S"/g' | sort | uniq -c | sort -rn
   ```
6. **Emitted patterns that broke, and their 0.17 forms:**

   | Emitted 0.16 code | 0.17 |
   |---|---|
   | `var t: [R][C]i16 = .{.{0} ** C} ** R;` | `var t: [R][C]i16 = @splat(@splat(0));` |
   | `for (@typeInfo(E).@"enum".fields) \|f\| arr[f.value] = …` | `for (@typeInfo(E).@"enum".field_values) \|v\| arr[v] = …` |
   | `pub const Role = enum(u16) {};` (empty, but stored in structs) | `pub const Role = enum(u16) { _ };` (an empty *exhaustive* enum must be `noreturn`-backed, which makes it uninhabitable) |
   | `return .{ .items = buf[0..len], .capacity = cap };` (ArrayList literal) | `var l: std.ArrayList(T) = .initBuffer(ptr[0..cap]); l.items.len = len; return l;` |
   | `if (std.debug.runtime_safety) …` | `if (@import("builtin").optimize.runtimeSafety()) …` |
   | `stack.getLast()` | `stack.last().?` |

7. **Migrate the generator first, then its consumers.** Once the generator
   emits 0.17 code, every consumer must be on 0.17 before it regenerates.
   Copies of consumer code inside the generator's test suite become 0.17 and
   are re-synced as each consumer migrates. When a consumer's port needs
   generator changes that are not released yet:
   - release the generator first (a major version if the generated API or
     the grammar rules break), after re-syncing the consumer's copies from
     the consumer's finished port;
   - pin that tag in the consumer's CI before the consumer's PR runs;
   - regenerate the consumer's checked-in output with the released binary
     (the header stamps the generator's version, so a pre-release build
     leaves a stale stamp);
   - re-sync the copies after any later change to them, a comment included.
8. **`zig fmt` 0.17 reformats files that were not fmt-clean** (it also
   unquotes enum fields such as `@"true"` → `true` and realigns tables).
   Expect layout churn in hand-maintained copies; review it, or land it in a
   separate formatting commit.
9. **Mechanical sweeps miss call-form arguments.** A pattern like
   `std.fmt.allocPrint(IDENT, ` does not match `std.fmt.allocPrint(self.allocator(), …)`;
   re-run the §23.2 sweep after every sed pass.
10. **A language that compiles to Zig ships a runtime in every program.**
    That runtime (often `@embedFile`d) and the emitter's strings are only
    compiled when a program is built, and OS-specific runtime code only for
    its OS. Cross-build emitted programs for each OS through a `ZIG` wrapper:
    ```bash
    printf '#!/bin/bash\nsub=$1; shift\nexec zig "$sub" -target x86_64-linux-musl "$@"\n' > zigx; chmod +x zigx
    ZIG=$PWD/zigx mylang build -o prog prog.src     # compile errors only; it does not run
    ```
    If the language exposes Zig builtins, rename them with Zig
    (`@fromBackingInt`, `@trunc`) and reject the old names with a hint.
11. **Prove a grammar or frontend migration changed nothing.** Dump the parse
    tree, the IR and the diagnostics of every source file and doc example
    with the old build and the new one, and diff them; every difference must
    be a planned one.

### 23.6 Measured: what 0.17 does to speed

From the parser-generator port above (Apple M5, ReleaseFast, best of two
full benchmark runs per version, run-to-run noise ≈ 0.4%):

| Measurement | 0.16 | 0.17 | Change |
|---|---:|---:|---:|
| generated MUMPS parser, parse 86.5 MB | 49.4 MB/s | 50.6 MB/s | +2.4% |
| generated Rig parser, parse 3.8 MB | 56.6 MB/s | 58.7 MB/s | +3.7% |
| generated lexers | 343.5 MB/s | 344.3 MB/s | unchanged |
| the generator itself, large grammars | 15.1 ms | 16.3 ms | −8% (slower) |
| the generator itself, small grammars | 2.34 ms | 2.35 ms | unchanged |

The generator's slowdown is a code-generation effect, not more work: with
identical page faults and memory, the 0.17 build retired **14% fewer
instructions** but spent **8% more cycles** (lower IPC). Measure this kind of
question with hardware counters, not wall time alone:

```bash
/usr/bin/time -l ./tool-016 input >/dev/null    # macOS: "instructions retired", "cycles elapsed"
/usr/bin/time -l ./tool-017 input >/dev/null
perf stat -e instructions,cycles ./tool input   # Linux
```

A compiler that emits Zig (Apple M5, interleaved A/B, two rounds): its own
front end (check 6,378 sources) runs at the same speed on both, within 2%
of instructions retired; cold debug builds of nine emitted programs, which
is mostly the Zig compiler's own time, take 8.1–8.4 s on 0.17 against 7.7 s
on 0.16 (5–9% slower).

An interpreter (bytecode VM, Apple M5 and x86-64): 0.17's LLVM inlines
less. `std.mem.eql(u8, …)` and `std.hash.Wyhash.hash` became out-of-line
calls at about 70 call sites that 0.16 inlined, which shrinks code and
cut instructions on most rows (up to 19% fewer), but a hot handler that
gains a call also gains a stack frame. A short-key compare written inline
(overlapping 4-, 8- or 16-byte loads from both ends, `std.mem.eql` only
past 32 bytes) restored the hot cache lookups; `@call(.always_inline,
std.mem.eql, …)` does not, as it still calls `eqlBytes`. Some loops
running the same or fewer instructions lost 1–6% of cycles to changed
branch layout (a `cmp`/`jne` emitted as `test`/`je`): measure cycles
across code placements, not instruction counts alone, and repeat a cycles
run before believing it (one taken while the OS indexed files showed a row
+9.5% that read +0.1% on a quiet rerun).

A Lisp runtime with an embedded database (Apple M5, 57 benchmark rows,
0.16 and 0.17 builds alternating): about 2–4% faster overall, transient
map and set construction 13–18% faster, after two fixes. Hashing went
through `std.hash.XxHash3`, 3–60× slower in 0.17 (§24); a local copy with
`readInt` loads (§5.3), checked against the published XXH3 vectors, put
every hash row back. Map encoding lost 28% because three small encoder
helpers (`header`, `named`, a ULEB128 writer) became calls; `inline fn` on
them restored parity. One row, 4096 appends to a transient vector, stayed
about 9% slower with the same code and calls on both: placement, not work.

Expect a 0.16 → 0.17 port to be mostly a syntax and API update with a small
throughput gain in hot loops; I/O-heavy programs see no change from the port
itself. Compare A/B binaries side by side (build the pre-port commit with 0.16
in a `git worktree`, interleave runs) before attributing any difference.

### 23.7 Performance triage for a port

What found every regression in the ports above, in order:

1. **Build the pre-port commit with 0.16** in a scratch directory and keep
   it as the A side. Run the whole benchmark suite A, B, B, A, and compare
   the minimum of each row's medians across runs, not one run's.
2. **Rerun only the rows that moved**, three or four times alternating. A
   row that moves in one direction every time is real; the rest is load.
3. **Diff the out-of-line symbols** of the two binaries for the module a
   slow row exercises. A function that 0.16 inlined and 0.17 calls is the
   usual cause:
   ```bash
   nm -n old/bin/tool | awk '$2 ~ /[tT]/ {print $3}' | grep -E 'codec|vector' | sort > a
   nm -n new/bin/tool | awk '$2 ~ /[tT]/ {print $3}' | grep -E 'codec|vector' | sort > b
   diff a b        # lines only in b: new calls; fix with `inline fn` on small hot helpers
   ```
4. **Suspect the standard library** when a row sits on a std primitive:
   microbenchmark it alone on both toolchains (`zig build-exe -OReleaseFast`
   with 0.16, `-Ofast` with 0.17).
5. **Watch for a row reading 0 ns.** A function that becomes `inline` with
   comptime arguments can fold a benchmark over constant input away; read
   the input through a `volatile` pointer.
6. **When code and calls match**, compare `cycles` with
   `/usr/bin/time -l` across placements before chasing it further (§23.6).

---

## 24. Known 0.17.0 bugs and release-note errata

**Release-note errata (verified against the shipped 0.17.0):**

| Release notes say | 0.17.0 actually has |
|---|---|
| `std.heap.StackFallbackAllocator` with `.init(@ptrCast(&buf), gpa)` | `std.heap.BufferFirstAllocator` (same usage) |
| `std.zon.fromSlice(T, .{ … })` | `std.zon.parse.fromSlice(T, .{ … })` |
| `--pkg-path` CLI arg | `--pkg-dir` |
| `{q}` "relaxed escaping rules" | `{q}` and `{qf}` are new relative to 0.16.0 |
| `std.Build.dependency` (a mid-cycle commit deprecated it) | not deprecated; supports lazy deps. Only `lazyDependency` is deprecated |

**Bugs and regressions to work around:**

- `std.Io.net.Stream.read` does not compile (*type 'Io.net.Stream.ReadResult'
  cannot be destructured*). Use `(try stream.readWithControl(io, &bufs,
  &.{})).data_len` or `stream.reader(io, &buf)`.
- `zig build -fincremental --watch` panics on aarch64-macos (*TODO(MachO2):
  load archive*).
- ZLS does not fully support 0.17.0 (build-runner removal).
- Listed by the release notes: compiler-rt fails for soft-float x86;
  `std.debug.simple_panic` fails to compile in some configurations (it
  compiled in our aarch64-macos probes); weak zig-libc symbols cannot be
  reliably overridden; response files with `std.Build.Step.Run` broke with the
  configurer/maker split; SPIR-V backend regressions.
- LLVM loop vectorization remains disabled.
- `std.hash.XxHash3.hash` is 2–9× slower than 0.16's for 17–240-byte
  inputs and 30–60× slower above 240 (aarch64-macos, `-Ofast`: 241 bytes
  517 ns against 8.4, 4 KiB 3.3 µs against 0.1). The values are
  unchanged. The short paths build words with array `@bitCast` (§5.3); the
  rewritten long path moves 64-byte stripes through an `extern struct`
  and `@bitCast`. A copy that loads words with `std.mem.readInt` and stripes
  through `*align(1) const @Vector(8, u64)` runs at 0.16's speed; pin it
  to the published XXH3-64 vectors (seeds 0 and 1: `""` →
  `0x2d06800538d394c2`, `"abc"` → `0x78af5f94892f3950`, the rest in
  `lib/std/hash/xxhash.zig`'s tests) so it stays bit-identical.
- A NaN converted to an integer is **not** safety-checked: `@trunc`,
  `@floor`, `@ceil`, `@round` with an integer result type, and the deprecated
  `@intFromFloat`, return 0 for NaN (aarch64-macos, debug and safe builds),
  while an out-of-range value panics. Guard with `std.math.isNan`.
- `Reader.allocRemaining` and `Dir.readFileAlloc` disagree on whether a
  limit of exactly the input size is allowed (§4.1.7).

---

## 25. Canonical 0.17 patterns (copy these)

Each block is a complete file that compiles and runs on 0.17.0.

### 25.1 A CLI program

```zig
const std = @import("std");
const builtin = @import("builtin");

const Options = struct { verbose: bool = false, inputs: []const []const u8 = &.{} };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();                 // one-shot CLI: arena, never free

    var opts: Options = .{};
    var inputs: std.ArrayList([]const u8) = .empty;
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-v")) opts.verbose = true else try inputs.append(arena, arg);
    }
    opts.inputs = inputs.items;

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (opts.verbose) try out.print("mode={t} os={t}\n", .{ builtin.optimize, builtin.target.os.tag });

    const cwd = std.Io.Dir.cwd();
    for (opts.inputs) |path| {
        const text = cwd.readFileAlloc(io, path, arena, .limited(16 << 20)) catch |err| {
            std.log.err("{s}: {t}", .{ path, err });
            continue;
        };
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |_| lines += 1;
        try out.print("{s}: {d} lines\n", .{ path, lines });
    }

    const report = try arena.print("{d} file(s)\n", .{opts.inputs.len});   // was std.fmt.allocPrint
    try out.writeAll(report);
}
```

### 25.2 A library function, a format method, and tests

```zig
const std = @import("std");
const Io = std.Io;

pub const Stats = struct {
    files: usize = 0,
    bytes: u64 = 0,

    pub fn format(s: Stats, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{d} files, {Bi}", .{ s.files, s.bytes });
    }
};

/// Library code takes `io` and an allocator; it never reaches for globals.
pub fn scan(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) !Stats {
    var stats: Stats = .{};
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const st = try entry.dir.statFile(io, entry.basename, .{});
        stats.files += 1;
        stats.bytes += st.size;
    }
    return stats;
}

test scan {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/x.txt", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/y.txt", .data = "678" });

    const stats = try scan(io, gpa, tmp.dir);
    try std.testing.expectEqual(2, stats.files);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print("{f}", .{stats});           // {f} calls format; {} / {any} would print the fields
    try std.testing.expectEqualStrings("2 files, 8B", out.written());
}
```

### 25.3 Child processes, concurrency, timing

```zig
const std = @import("std");
const Io = std.Io;

fn countLines(io: Io, gpa: std.mem.Allocator, argv: []const []const u8, result: *usize) void {
    const r = std.process.run(gpa, io, .{ .argv = argv }) catch return;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    result.* = std.mem.count(u8, r.stdout, "\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;                                 // long-lived style: SafeAllocator in Debug, leaks reported at exit

    const t0 = Io.Clock.awake.now(io);

    var results: [2]usize = .{ 0, 0 };
    var group: Io.Group = .init;
    defer group.cancel(io);
    group.async(io, countLines, .{ io, gpa, &.{ "printf", "a\\nb\\n" }, &results[0] });
    group.async(io, countLines, .{ io, gpa, &.{ "printf", "x\\n" }, &results[1] });
    try group.await(io);

    var child = try std.process.spawn(io, .{ .argv = &.{ "sh", "-c", "exit 0" } });
    const term = try child.wait(io);

    var mutex: Io.Mutex = .init;
    try mutex.lock(io);
    mutex.unlock(io);
    try io.sleep(.fromMilliseconds(1), .awake);

    const elapsed_ms = @divTrunc(t0.untilNow(io, .awake).toNanoseconds(), std.time.ns_per_ms);
    std.debug.print("lines={d},{d} child={f} ok={} elapsed={d}ms\n", .{ results[0], results[1], term, term.success(), elapsed_ms });
}
```

### 25.4 Reflection-driven code (0.17 shape)

```zig
const std = @import("std");

/// Print every field of any struct as `name=value`, using the 0.17 struct-of-arrays @typeInfo.
fn dump(w: *std.Io.Writer, value: anytype) !void {
    const info = @typeInfo(@TypeOf(value)).@"struct";
    inline for (info.field_names, info.field_types, 0..) |name, T, i| {
        if (i != 0) try w.writeAll(" ");
        switch (@typeInfo(T)) {
            .pointer => try w.print("{s}={s}", .{ name, @field(value, name) }),
            .@"enum" => try w.print("{s}={t}", .{ name, @field(value, name) }),
            else => try w.print("{s}={any}", .{ name, @field(value, name) }),
        }
    }
}

const Mode = enum(u8) { off, on };
const Cfg = struct { name: []const u8, port: u16 = 80, mode: Mode = .on };

test dump {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump(&w, Cfg{ .name = "svc" });
    try std.testing.expectEqualStrings("name=svc port=80 mode=on", w.buffered());
    try std.testing.expectEqual(1, @backingInt(Mode.on));
    try std.testing.expectEqual(Mode.off, @as(Mode, @fromBackingInt(0)));
    const zeros: [4]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &zeros);
}
```

---

## Appendix: sources and verification

- Official: 0.17.0 and 0.16.0 release notes
  (ziglang.org/download/0.17.0/release-notes.html), the 0.17.0 language
  reference, `git log 0.16.0..0.17.0` of codeberg.org/ziglang/zig.
- Diffs of the installed 0.16.0 and 0.17.0 `lib/std` and `lib/init`, and of
  `zig --help` / `zig build --help` / `zig fetch --help` outputs.
- Consolidated 0.15 → 0.16 field notes from four real migrations (a MUMPS
  engine, an embedded B+-tree database, a Clojure-dialect runtime, and a
  language compiler that emits Zig).
- A complete 0.16 → 0.17 port of a self-hosting parser generator (517-test
  suite, byte-exact golden outputs, before/after benchmarks), the source of
  §23.5 and §23.6.
- Community guides cross-checked (all written against 0.17.0-dev snapshots,
  so treat them as background only): "What Changed in Zig 0.17" (Zig Guide
  Live), `nzrsky/zig-skills`, codedb's `docs/zig-0.17-migration.md`. Where
  they disagree with this file — for example `std.time.Timer` still existing,
  `std.fmt.bufPrintSentinel` being the replacement for `bufPrintZ`, or
  `stream.read` being usable — this file reflects the final 0.17.0.
- Verification: every listed API and every complete code block was compiled
  with Zig 0.17.0 on aarch64-macos (most also with 0.16.0 to confirm the old
  form). x86_64-linux, Windows and big-endian behaviour is from the release
  notes and std source, except the `@bitCast` big-endian table, which was
  evaluated at comptime for s390x and powerpc64 targets.
