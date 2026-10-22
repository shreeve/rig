# Zig 0.17 audit of the Zig that Rig owns

Scope: `src/runtime.zig` (shipped with every program), the Zig that `src/emit.zig` generates (read the emitter, and the
emitted packages of `examples/{hello,ownership_tour,shapes,tree,sort}.rig`, `test/behavior/types/simd_bytes.rig`
and the probes below), `std/*.zig`, `build.zig`, and `src/main.zig`'s invocation of `zig`. The compiler's own internals
were read only for what they pass to Zig.

Against: the owner's guide (ZIG-0.17.md, gist 57a74df35e17dacb30dcaa5d5164a27f, read in full), with the installed
0.17.0 std (`~/.local/share/mise/installs/zig/0.17.0/lib/std`) as the authority where the guide is silent.
Machine: aarch64-macos, Zig 0.17.0, LLVM 22.1.8. Linux/x86 was not run; x86 code was disassembled, not executed.
Repo: `main` at 741526cb1. No code was changed.

Method: the guide's §23.2 grep sweeps over runtime/std/build/main; each §4.1 and §4.2 trap checked by hand; every
`@hasDecl` traced to its `pub` declaration; reading `runtime.zig` end to end against the 0.17 allocator, writer, panic,
process and reflection APIs; cross-builds of emitted programs for five targets; and repros run through
`cpuq run --cores 1` only when `cpuq status` showed no waiters (four short batches, label `rig:zigaudit`).
Evidence: `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/6111da4f-b659-4a9c-9353-65e429d1d5f8/scratchpad/`
(`zg/` Zig probes, `rg/` Rig probes, `zgout*/` outputs).

## Verdict

No trap of §4.1 or §4.2 is hit, and nothing the guide lists as a known 0.17.0 bug is hit unguarded. The runtime is
already written in the 0.17 idiom (struct-of-arrays reflection, `@Int`/`@Tuple`, `Writer.Allocating.fromArrayList`,
`FullPanic`, `Init.Minimal`, unmanaged `ArrayList`).
Three real defects (all small) and one portability wall turned up; the rest is deprecation and one documentation gap.

| # | Finding | Class | Where |
|---|---|---|---|
| 1 | Buffered `print` output is lost when the program dies of a signal (stack overflow, any SIGSEGV) | real bug | `runtime.zig:2457-2485`, `emit.zig:752`, `main.zig:580` |
| 2 | A failed write to stdout is swallowed; the program exits 0 | real bug | `runtime.zig:2471-2485`, `2437-2443` |
| 3 | `--release=fast`: division and remainder by zero, and over-wide shifts, give garbage, and SPEC does not say so | doc gap / real in fast mode | `SPEC.md:87-95`, `emit.zig:4225-4240`, `6940-6960` |
| 4 | `std.heap.smp_allocator` is a compile error on single-threaded targets (wasm32-wasi, `-fsingle-threaded`) | latent, blocks planned WASM | `runtime.zig:371,420,566,2028,2037,2041,2142` |
| 5 | `-Dnexus=REL` is resolved against the cwd but cached by its text | latent | `build.zig:31-34` |
| 6 | Emit relies on Zig emitting no lifetime markers; true today, pinned by nothing | latent | `docs/INTERNALS.md:3156`, `emit.zig` `zigTemporary` |
| 7 | `io().random` falls back to a guessable seed if OS entropy is unavailable; the doc says OS entropy | latent | `std/random.zig:7-9`, `Threaded.zig:17899-17910` |
| 8 | Deprecated spellings that compile (removal after 0.18) | style | listed in section 3 |
| 9 | `docs/zig-0.17.md` §16 lists one Zig issue; the nine already found, and the above, belong there | docs | `docs/zig-0.17.md:1320` |

## 1. Real bugs

### 1.1 Output is lost on a crash signal (runtime.zig:2457-2485; emit.zig:752; main.zig:580)

`rig.print` writes into an 8 KiB process-wide buffer (`stdout_buffer`) that is flushed by `finish`, `failMain`, the
panic handler and, on a terminal, after every print. The guide's §4.2.8 ("Nothing is written until `flush()`") and
§19.2 cover the panic path, and Rig handles it (`panicAfterFlush`). A SIGSEGV/SIGBUS/SIGILL/SIGFPE does not go through
the panic handler. Zig's `defaultHandleSegfault` runs, prints the trace, aborts, and the buffer is never flushed.
`Sanitizer.onFault` (runtime.zig:2268-2283) already flushes first, so the intent exists on that path only.

Rig promises that a stack overflow "stops the program" (`guardStack`, SPEC.md:445), and that is how it ends:
by SIGSEGV. Everything printed before it, up to 8 KiB, is gone when stdout is a pipe or a file.

Repro (`scratchpad/rg/stack.rig`, `rig build -o stack stack.rig; ./stack | cat`, debug and `--release`):

```
fun down(n: Int) -> Int
  if n == 0
    return 0
  1 + down(n - 1)

sub main()
  print("before")
  print(down(100000000))
```

Output: `Segmentation fault at address 0x16abebfe8`, the trace, exit 134; `before` never appears (0 matches in both modes).

Fix, verified in a scratch copy of the emitted package (the runtime's `flush` made `pub`): next to
`pub const panic = rig.panic;` (emit.zig:752 and the test driver, main.zig:580) emit

```zig
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        rig.flushOutput();
        std.debug.defaultHandleSegfault(addr, name, ctx);
    }
};
```

Result: `before` printed, exit 134. The hook is `root.debug.handleSegfault`, read by `std.debug.handleSegfault` in
`debug.zig:1667`; the guide does not mention it (addendum, §19.2).
Limit: Zig installs its segfault handler only when `std.options.enable_segfault_handler` is true, which defaults to
`runtime_safety and ...`. In `--release=fast` there is no handler and no hook; flushing there needs Rig's own
`sigaction` (as `Sanitizer.installHandler` does) or `pub const std_options: std.Options = .{ .enable_segfault_handler = true }`.
Sibling sites checked: `failMain` (flushes), `finish` (flushes), `exitStatus` panic (after `finish`), `guardStack` exit
(nothing buffered yet), `runTests` (flushes per test), `std.process.exit` calls (all after `flush()`).
A test that would catch the class: a `test/cli` script that overflows the stack with a pipe on stdout and expects the
earlier lines.

### 1.2 A failed stdout write is swallowed (runtime.zig:2471-2485, 2437-2443)

`print` ends each write with `catch {}`, `flush` with `catch {}`, and `finish` exits 0 after a flush that failed.
Output sent to a closed descriptor or a full disk is lost and the program reports success.

Repro, macOS (`/dev/full` does not exist there; on Linux `./hello > /dev/full` is the same): `./hello >&-; echo $?` prints `0`.
(`rg/hello.rig`; `zgout2/r2_closed.txt`.) A write to a pipe with no reader should die of SIGPIPE, as in C (not run; `global_single_threaded` does not run `Threaded.init`, which is where std changes SIGPIPE).

The guide (§9) keeps the cause on the implementation: `stdout_writer.?.err`. Suggested: remember the first
`error.WriteFailed` in `print`/`flush`, and have `finish` print `error: rig: cannot write to stdout: <err>` and exit 1.

### 1.3 Fast mode: division by zero and wide shifts are not checked, and SPEC lists only overflow and conversion (SPEC.md:87-95)

`--release=fast` is `-Ofast` (main.zig:111-115). SPEC names integer overflow and out-of-range conversion as the
checks it drops. Division and remainder by zero, and shifts by the width or more, are also unchecked by Zig in that mode,
and the emitter relies on Zig for them (`@divTrunc`, `rig.rem`, `@shlExact` with `@intCast`).

Repro (`rg/div.rig`, `rig run <mode> div.rig`, args: none, so the divisor is 0 at run time):

```
debug         panic: division by zero
--release     panic: division by zero
--release=fast
  quotient 0              (7 / 0)
  remainder 7             (7 % 0)
  <killed by signal 5>    (1 << 70)
```

Wrong values with no signal on aarch64; on x86 `idiv` raises SIGFPE (not run here), so the same program differs by target.
Either say so in SPEC (add "division and remainder by zero, a shift by the type's width or more" to the list in §1) or
check explicitly in fast mode as `index` does. Tests `inline_divide_literal.rig` etc. use `# release`, so nothing
exercises fast mode here.

## 2. Latent

### 2.1 `smp_allocator` cannot be named on a single-threaded target (runtime.zig:371,420,566,2028,2037,2041,2142)

`SmpAllocator.zig:114-116` has `comptime { assert(!builtin.single_threaded); }`. The runtime names
`std.heap.smp_allocator` for the release allocator, the leak checker's table, the drop queue and the sanitizer fallback,
so a program for `wasm32-wasi` (single-threaded by default) or built with `-fsingle-threaded` cannot compile.
The runtime has WASM-specific code (`wasmSimd`, `maskBitsSwar`) and the README/PROPOSAL plan a WASM target.

Repro (`zg/b6_smp.zig`, or any emitted program with `ZIG=` wrapper `zig "$sub" -target wasm32-wasi "$@"`):

```
SmpAllocator.zig:115:11: note: called at comptime here
    assert(!builtin.single_threaded); // you're holding it wrong
```

Everything else in the runtime survives the swap: with `std.heap.smp_allocator` replaced by `std.heap.wasm_allocator` in
a scratch copy, `ownership_tour` and `simd_bytes` build and print the right output under wasmtime, Debug and ReleaseSafe
(`zgout2/w_*`). The other targets compile cleanly from this machine: x86_64-linux-musl, aarch64-linux-musl, x86_64-macos
and x86_64-windows-gnu, with and without `RIG_SANITIZE=1 RIG_LEAK_TRACE=1` on the two Linux targets
(`zgout/x_*`, `xs_*`). Suggested: one `const base_allocator = if (builtin.single_threaded) std.heap.wasm_allocator ... else std.heap.smp_allocator`
(or `brk_allocator` for single-threaded Linux).

### 2.2 `build.zig` caches a cwd-relative path by its text (build.zig:31-34)

`-Dnexus=PATH` is resolved with `currentPathAlloc` at configure time, but the configuration is keyed by the option
string (guide §4.1.3, §20.4). A second `zig build -Dnexus=nexus/bin/nexus` from a different directory reuses the first
directory's absolute path. Verified in a stand-in `build.zig` (`scratchpad/cc/`):

```
(cd a) zig build -Dtool=tool show  ->  configured with .../cc/a/tool
(cd b) zig build -Dtool=tool show  ->  configured with .../cc/a/tool     (wanted .../cc/b/tool)
```

`findNexus` is fine: it declares what it found with `dependOnFileMetadata` and poisons the cache when it finds nothing,
which is the guide's recipe. Fix for the option: resolve against `b.root`, or accept only absolute paths.

### 2.3 Emit's temporaries rely on Zig emitting no lifetime markers (docs/INTERNALS.md:3156)

INTERNALS says "Zig keeps each until its statement ends (it emits no lifetime markers)", for `&@as(T, value)` and
temporary arrays lent to a call. The guide says nothing about it. Checked on 0.17.0: `use(&S{...})` twice in one
function, `-O ReleaseFast -femit-llvm-ir`, has 0 `llvm.lifetime` occurrences (`zgout/c1.count.txt`). The
assumption holds, and the sanitizer's poisoning covers it in tests, but no CI check pins it. Cheap pin: a `test/cli`
script that greps the IR of that function.

### 2.4 `io().random` is not an OS-entropy call (std/random.zig:7-9)

`rig.io().random` is a per-process CSPRNG seeded from `randomSecure`; when entropy is unavailable it silently falls
back to pid + clock + ASLR address (`Threaded.zig:17899-17910`, `fallbackSeed`). The guide (§13.5) calls it "fast,
non-crypto". The doc comment "the operating system's entropy" is stronger than that. For `Random.new` seeding this is
acceptable; if the doc stays, use `randomSecure` and fail loudly (`error.EntropyUnavailable`).

### 2.5 The global single-threaded `Io` is used only for leaf calls (checked, clean)

`rig.io()` is `Threaded.global_single_threaded` (guide §4.2.1: its allocator fails). Uses: clocks, sleep, `random`,
`isTty`, `writerStreaming`, `Dir.createFile`/`readFile` in `start`/`Sanitizer.configure`. All leaf. Process spawning in
`main.zig` uses `init.io`. If a stdlib shim ever spawns, reads a directory, or touches the network, it would fail with
`OutOfMemory`; the shim table is small enough to review at that point.

## 3. Style and deprecated (compile today; removal after 0.18)

| Where | Now | 0.17 spelling |
|---|---|---|
| `runtime.zig:854` | `builtin.mode == .debug` | `builtin.optimize == .debug` |
| `runtime.zig:1103,1136,1559,1570,1679,1720,1823-1829,1911,1921` | `builtin.cpu.arch`, `builtin.cpu.features` | `builtin.target.cpu.*` |
| `runtime.zig:957,968` | `std.mem.copyBackwards`, `copyForwards` ("deprecated; use @memmove") | `@memmove`. Not slower: 17-38 ms either way over 3 rounds of 1 GiB (`zgout2/b1_*`) |
| `runtime.zig:1285-1286` | `std.mem.lastIndexOfScalar` | `findScalarLast` |
| `runtime.zig:1285` | not `zig fmt` clean (one line, `[0 .. x]`) | `zig fmt` |
| `build.zig:50-52` | `addFileArg`, `addOutputFileArg` | `addFileArg2`, `addOutputFileArg2` |
| `build.zig:136`, `main.zig:286,475-776,937,1161-1263` | `std.fs.path.*` | `std.Io.Dir.path.*` |
| `main.zig:564,921,989` | `std.fs.max_path_bytes` | `std.Io.Dir.max_path_bytes` |
| `main.zig:565,922,990,1137` | `std.fmt.bufPrint` | `std.mem.print` |
| `main.zig:1215` | `std.fmt.allocPrint` | `allocator.print` |

Not in scope but seen: `src/emit.zig:6995,7012,7030` use `ArrayList.getLast()` (deprecated for `last().?`), and
`emit`, `proofs`, `rig`, `sema`, `storage`, `typecheck` are not `zig fmt` clean.

The guide's own sweep list does not include `copyForwards|copyBackwards`; the addendum adds it.

## 4. Checked and clean

| Guide item | Result |
|---|---|
| §4.1.1 `containsAtLeastScalar` | not used |
| §4.1.2 `@hasDecl` sees only `pub` | every tested decl is `pub`: `__rig_drop` (emit.zig:718), `__rig_name` (646), `__rig_tests` (503), `__rig_print`, `__rig_list`, `__rig_string`, `__rig_box`, `__rig_rcbox`, `__rig_weak`, `__rig_args`, `__rig_fn`, `cloneWeak`; the root flags `__rig_sanitize`, `__rig_leak_trace`, `__rig_verify_proofs`, `__rig_run_started` are written `pub const` (main.zig:168-172) |
| §4.1.3 `build()` is cached | `findNexus` follows §20.4 exactly; the one gap is 2.2 |
| §4.1.4 Run-step path args are relative | the Nexus binary is passed as an absolute `cwd_relative`; the grammar and output as `b.path`/output args, which work from the build root; no path is printed or reused |
| §4.1.5 `@tagName(builtin.mode)` | not used |
| §4.1.6 `init.gpa` is `SafeAllocator` | not used; runtime has its own allocator; `SafeAllocator` only under `RIG_LEAK_TRACE` (opt-in, slow by design, §4.2.2) |
| §4.1.7 `allocRemaining`/`readFileAlloc` limit | `main.zig:703` uses `.limited(len + 1)`; `modules.zig` limits are caps |
| §4.1.8 `@bitCast` of arrays/vectors | little-endian targets only; vector<->int casts only; array<->vector casts are in the unpadded `[n]u8` fallback of `simdLoad`/`simdStore` |
| §4.1.12-13 `bit_set`, `mem.eql` on floats | `rig.eql` compares float slices elementwise (runtime.zig:269 comment); no bit sets |
| §4.1.17 test results replayed | AGENTS.md already uses `--cache-dir "$(mktemp -d)"` |
| §4.2.1 global single-threaded `Io` | leaf calls only (2.5) |
| §4.2.3 `Writer.Allocating.written()` | `String.add` uses `fromArrayList`/`toArrayList`; main.zig takes `written()` once |
| §4.2.7 copying a `File.Writer` | the writer is copied once into a global before its `interface` address is taken |
| §4.2.8 flush before exit | `finish`, `failMain`, panic, tests flush; see 1.1 for the signal path |
| §4.2.10 unchecked native stack | `guardStack` (macOS reserve, Linux rlimit) |
| §5.1 removed syntax, §2 reflexes | none present (sweeps over runtime/std/build/main are empty except the deprecations in 3) |
| §6 reflection | all `@typeInfo` uses are struct-of-arrays |
| §14 allocator vtable | `alloc/resize/remap/free` in `LeakChecker` and `Sanitizer` match the contract; `remap` returns null where it cannot grow |
| §19.2 panic handler | `std.debug.FullPanic(panicAfterFlush)`, then `defaultPanic(msg, first_trace_addr orelse @returnAddress())` |
| §24 NaN to integer | handled by `rig.notNan` on every float-to-int conversion (emit.zig:5662-5671) |
| §24 XxHash3 | not used (the leak checker's map uses Wyhash; debug only) |
| §20.2 `build.zig` | `.root_module`, `getEmittedBin` + `addCopyFileToSource`, `addPassthruArgs`, `dependOnFileMetadata`, `poisonCache`: the guide's patterns |
| Cross targets | emitted packages build for x86_64-linux-musl, aarch64-linux-musl, x86_64-macos, x86_64-windows-gnu; only wasm32-wasi fails (2.1) |

## 5. Recommendations, in order

1. Add the `debug.handleSegfault` hook to the emitted root and the test driver, and cover it with a `test/cli` script (1.1).
2. Record the first stdout write failure and exit 1 in `finish` (1.2).
3. Decide fast-mode division and shifts: document them in SPEC.md §1 or check them (1.3).
4. Pick the allocator by `builtin.single_threaded` before the WASM work starts (2.1).
5. Resolve `-Dnexus` against `b.root` or require an absolute path (2.2).
6. Move the nine Zig findings (addendum) and 1.1/2.1 into `docs/zig-0.17.md` §16, replacing the single NaN entry.
7. Sweep the deprecations in section 3 in one pass, adding `copyForwards|copyBackwards` to the sweep.
