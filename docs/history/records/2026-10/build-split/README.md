# Building Trig as several units: a study

A design study approved by the owner on 2026-10-31. No compiler change was
made, nothing was committed, and there is no PR. Everything ran on the Mac
(M5, 10 cores, 32 GB) on 2026-10-31, with Zig 0.17.0, a Rig built from
origin/main at 36be46744, and Trig at 2ba0719.

## The question

Trig is 193k lines of Rig. Rig emits it as 68 Zig files, 243k lines, 19 MB,
which one `zig build-exe` compiles as one LLVM module on one core. The
question was whether Rig can build Trig as several units, compiled on
separate cores and linked, and what that costs Trig at run time, with and
without cross-unit optimization (LTO).

The answer: yes. Eight units build Trig in 57 s of Zig time against 448 s
today (about 8 times faster), in about the same memory, and the program
prints byte for byte what today's prints. At run time it costs 8% to 21%,
depending on how the functions are cut; LTO, which would win that back,
does not exist on the Mac in Zig 0.17.

## What Zig 0.17 offers

Read from `zig build-exe --help`, the installed std
(`lib/std/zig.zig`, `lib/compiler/Maker/Step/Compile.zig`), and small
programs compiled to test each claim.

| Option | What it does on the Mac |
|---|---|
| Parallel LLVM codegen (codegen units, LLVM threads) | Not offered. `-j<N>` limits the compiler's job pool (C objects, the self-hosted backends); one Zig compilation is one LLVM module, optimized on one thread. |
| `-flto`, `-flto=full`, `-flto=thin` | The kinds exist (`std.zig.LtoMode = { none, full, thin }`), but LTO needs LLD: `error: LTO requires using LLD`, and with `-flld`, `error: using LLD to link macho files is unsupported`. No LTO on macOS. |
| LTO through Apple's linker | Apple clang 21 cannot read Zig 0.17's LLVM 22 bitcode: `Unknown attribute kind (105) (Producer: 'zig 0.17.0' Reader: 'LLVM APPLE_1_2100.4.1.1_0')`. No llvm-link, llvm-split or LLVM tools are installed. |
| `zig build-obj` per unit, linked by `zig build-exe` | Works. Each object is a separate compilation and may run on its own core. |
| `-fincremental` | Panics on a hello world: `TODO(MachO2): load archive`. |
| The self-hosted aarch64 backend (`-fno-llvm`, Debug) | A hello world took 100 s and wrote a binary that does not run (`exec format error`). |
| Caching | Each compilation caches under its `--cache-dir`, keyed by its inputs: an object whose unit's files are unchanged is not rebuilt. |

Where the time goes: Zig's front end, every function of Trig analyzed
(`zig build-exe -fno-emit-bin`), takes 5.6 s and 0.34 GB. The other 99% of
the 448 s is code generation: Zig lowering to LLVM IR, then LLVM's
optimization and machine code, all on one thread. So splitting the LLVM
module is everything; the front end is not worth parallelizing.

## The prototype

`tools/split.py` cuts the package `rig build --release` emits into N
units; `tools/x.zig` holds the calls between them; `tools/build.sh` builds
the units in parallel and links them; `tools/timeit.py` times the binaries.

**Who owns what.** Each function of a Trig module (a file not under `rig/`
and not named `__rig_*`) that can cross a unit is owned by one unit. In
its unit it keeps its body and is exported; in every other unit its body
is replaced by a call to that export (`return __rig_x.call(@This().f,
"rigx_checker__Checker__f", .{ self, a });`). Of Trig's 9,660 functions,
4,282 (129k lines of body) are cut this way. The rest stay in every unit
that uses them: 5,270 `inline` functions (Rig's inliner marks them; 46.5k
lines of body), 86 with a `comptime` or `anytype` parameter, and 22 whose
result is an inferred error set or depends on a parameter. The runtime
(`rig/`), std's emitted modules and the root stay whole in every unit,
compiled where used.

**Calls between units.** Zig exports and imports only types with a
guaranteed layout. A Zig function with a slice, an optional value, an
error union or an ordinary object in its signature cannot be exported at
all (`unable to export type ... struct with automatic layout has no
guaranteed in-memory representation`), and a symbol of such a type cannot
be declared extern. So a function whose parameters and result C takes
(integers to 64 bits, bools, floats, pointers that are not slices,
optional pointers, packed objects) is exported as itself in the C
convention and called directly; any other is exported as a thunk that
takes its arguments as a tuple and the place for its result, both by
pointer. The tuple has one layout in every unit, since every unit is
compiled by the same Zig from the same declarations. The first two
8-unit builds below (s4, s8) used the tuple for every call; s8b used the
direct call where it could.

**Errors.** Each Zig compilation numbers errors in the order it first
meets their names. An error returned across two units came back as a
different error (a test: `error.Worse` returned as
`error.SystemResources`). Every unit's root therefore names all 706 error
names the program can make (Rig's and Zig std's, gathered from the
sources) before anything else, so each numbers them alike, and the entry
checks at start that every unit computes the same signature of the
numbering. This works only because every unit is a `zig build-obj`: an
executable's root numbers std's start-up errors first. The executable's
root is therefore a stub whose `main` calls unit 0's `rig_entry`.

**The runtime's globals.** The runtime written beside each program has 70
module-level variables (13 in alloc.zig, 31 in runtime.zig, 25 in
sched.zig, 1 in tasks.zig; 6 of them thread-local): the allocator's heaps,
the scheduler's workers, stdout's buffer, the panic state. Compiled into
each unit, each unit would have its own. Each becomes one storage, an
aligned byte array defined in unit 0 and declared extern in the others,
reached through a pointer; unit 0 sets the initial values at entry, and
the thread-local ones start as zero bytes on every thread. Zig std's own
globals (std.debug's lock, for one) stay one per unit; Trig did not mind.

**The root's declarations.** The runtime reads the program's settings
from `@import("root")` (`__rig_tasks`, `__rig_error_glue`, `std_options`,
`panic`); each unit's root names those of `__rig_main.zig`.

**The cut.** s4 and s8 cut the functions, in file order, into N runs of
about equal lines. s8b weighted each module's lines by what one of its
lines cost to compile in s4 and s8 (fitted below) and then moved
functions toward the units their calls go to, by a static call graph
(20,180 edges between call sites, found by name), within 3% of balance:
that cut 41% of the call edges' weight across units, against 55% for the
same cost-weighted cut in file order before the moves.

**Correctness.** All three split binaries print exactly what today's
binary prints, with the same exit status, on Trig's six cli projects
(mitt, neverthrow, superstruct, tiny-invariant, ts-pattern, zod3), both
`--noEmit` and `--pretty` with emit, the emitted files compared byte for
byte. Trig's checkers ran as tasks on several cores in every unit, so the
shared scheduler and allocator worked. Trig's own test suites were not
run.

## Build time and memory

Times are Zig's part of the build (the units in parallel, then the link).
`rig build` itself checks and emits Trig in about 8 s more, in every row;
`rig check` alone takes 3.6 s. Each build ran alone, holding `tools/heavy`.

| Build | Wall | CPU (user) | Peak memory | Binary | `__TEXT` |
|---|---|---|---|---|---|
| Today: 1 unit (`rig build --release`) | 456 s (448 s Zig) | 445 s | 11.7 GB max RSS | 16.7 MB (15.2 MB stripped) | 14.8 MB |
| s4: 4 units, plain cut | 88 s (84 + 3.5 link) | 239 s | 10.0 GB summed, 4.8 GB largest unit | 19.8 MB (17.4 MB) | 16.6 MB |
| s8: 8 units, plain cut | 57 s (53 + 3.6 link) | 298 s | 10.5 GB summed, 2.8 GB largest unit | 21.9 MB (18.9 MB) | 17.9 MB |
| s8b: 8 units, call-graph cut, direct calls | 56 s (53 + 3.8 link) | 341 s | 11.1 GB summed, 2.3 GB largest unit | 21.5 MB (18.6 MB) | 17.7 MB |

Peak memory for a split build is the sum of every zig process's RSS,
sampled every 0.2 s (`data/build-*/rss-peak-kb.txt`). The owner's figure
of 8.5 GB for today's build is lower than the 11.7 GB maximum RSS measured
here.

Eight units build 7.9 times faster than one (7.1 times counting `rig
build`'s 8 s), in less total CPU (298 s
against 445 s): LLVM's cost grows faster than the size of its module, so
eight small modules cost less than one large one, despite the code each
unit duplicates.

**Balance.** The units are not equal. In s8 they took 27 s to 53 s; the
last, with transformers.zig and tsoptions.zig, set the wall time. A fit of
every unit's time in s4 and s8 to the lines it owns per module
(`data/unit-cost-fit-rows.json`, 12 units, predicted within 3 s each)
gives a fixed 16.4 s per unit (the runtime, std, inline and generic code
each unit compiles again) plus, per 1,000 lines owned: checker 0.88 s,
ast and binder 1.45 s, parser and lexer 1.12 s, printer 1.18 s,
transformers 2.97 s, tsoptions and tspath 1.17 s, the rest 2.13 s. So
eight perfectly balanced units would take about 16 + 175/8 = 38 s, and
ten (one per core) about 34 s; the fixed 16 s per unit is the floor. s8b,
balanced by that model, ranged 36 s to 52 s: moving functions toward
their callers scattered modules across units, and each unit then compiled
more of the code it shares, so the model's costs no longer held (341 s of
CPU against 298 s).

## Run-time cost on Trig

Trig `-p tsconfig.trig.json --noEmit` in `misc/projects/<p>`, 30 rounds,
the four binaries interleaved with the order rotated each round, under
`tools/low` (`data/timing-round3.*`; rounds 1 and 2, of 15 and 20, agree
within a few percent). The machine was not idle: other sessions' builds
held one core throughout, load average 5 to 7, so the instruction counts
are the steadier measure.

ts-pattern:

| Binary | Fastest | Median | Instructions | Against today |
|---|---|---|---|---|
| Today, 1 unit | 239.8 ms | 259.8 ms | 10.25 G | |
| s4 | 275.9 ms | 301.6 ms | 11.62 G | 15% slower (fastest), 16% (median), 13% more instructions |
| s8 | 290.5 ms | 308.3 ms | 11.83 G | 21% slower, 19%, 15% more instructions |
| s8b | 257.7 ms | 287.5 ms | 11.08 G | 7.5% slower, 11%, 8.1% more instructions |

zod3:

| Binary | Fastest | Median | Instructions | Against today |
|---|---|---|---|---|
| Today, 1 unit | 71.0 ms | 79.9 ms | 2.55 G | |
| s4 | 80.6 ms | 88.6 ms | 2.90 G | 14% slower, 11%, 14% more instructions |
| s8 | 84.2 ms | 89.1 ms | 2.97 G | 19% slower, 12%, 17% more instructions |
| s8b | 77.7 ms | 87.3 ms | 2.79 G | 9.4% slower, 9.2%, 9.6% more instructions |

Peak RSS is unchanged (312 against 315 MB on ts-pattern).

The cost is the calls between units: a call that LLVM inlined or
specialized today is now an opaque call to another object, and in s4 and
s8 every such call also packs its arguments into memory. More units cost
more. Calling directly in the C convention where the signature allows,
and cutting along the call graph, together halved the cost (s8 to s8b);
which of the two did more was not measured separately.

**With LTO.** Not measurable on the Mac: Zig 0.17 has no LTO for Mach-O.
On Linux Zig links with LLD, where `-flto=thin` objects from separate
`build-obj` runs should link with cross-unit inlining restored; that is
the next measurement, on pup.

Against Trig's bar (a change must not make it 1.5% slower), no split
build qualifies for the release Trig is timed with. It qualifies for the
builds where build time is the cost: debug builds, test packs, and the
edit-build-run loop.

## What blocks a split, and what does not

| Construct | Effect |
|---|---|
| Generic functions and types (Map, List, Table instantiations) | Not a blocker: compiled again in every unit that uses them. Part of the 16 s each unit pays, and of the 12% to 21% larger code. |
| `comptime` and `anytype` parameters | Not cut: the 86 such functions stay in every unit. No cut function was needed at compile time; Zig would have said so. |
| Inline functions | Not cut: 5,270 of Trig's 9,660 functions, replicated, inlined at each call site in each unit. |
| Inferred error sets (`!T`) | Not cut (the result type depends on the body): 22 functions. |
| Signatures with slices, optionals, error unions, objects | Cannot be exported or declared extern in Zig: they cross only through a tuple thunk, arguments and result in memory. |
| Errors | Each compilation numbers them itself. Fixed by naming every error first in each unit's root, which relies on the order in which Zig 0.17 numbers errors, an undocumented behaviour, and is checked at start-up. |
| The runtime written beside each program | Its 70 globals must be one storage: extern cells defined in unit 0. Its code is otherwise compiled into each unit. Zig std's few globals stay one per unit. |
| Constants compared by address (an empty Map's shared groups, vtables) | One copy per unit, so an address compare across units would fail. Trig compares none; a risk for other programs. |
| Exported symbols and `@import("root")` | Each unit's root names the root's settings; the executable's root is a stub calling unit 0, so start-up and the error numbering stay apart. |
| A method named as a function of its file | Ambiguous when named bare: the stub names `@This().f`. |

## What it would take in the compiler

- **A unit pass** (beside `src/inlining.zig`, which already decides what
  is inlined program-wide): give each function that may cross units an
  owner, by a cost per line and the call graph, or by a `--pgo` profile's
  call counts, and record it as a fact. The functions inlining keeps
  inline, the generic ones and the comptime ones stay in every unit.
- **Emit** (`src/emit.zig`, reading the fact through `src/facts.zig`):
  for each unit, each module's file with the bodies the unit owns and a
  stub for the rest, and an export for each owned function, direct in
  the C convention when its signature allows, else a thunk. A unit's file
  holds only stubs for others' functions, so an edit to one function
  changes one unit's files, and Zig's cache rebuilds that unit alone
  (about 30 s to 50 s plus a 4 s link, not measured). Each unit's root
  names every error first and names the root's settings; unit 0 exports
  `rig_entry` and the executable's root calls it.
- **The runtime** (`src/runtime.zig`, `sched.zig`, `tasks.zig`,
  `alloc.zig`): each module-level variable behind one global cell, once,
  by hand, so the runtime is the same whether a program is one unit or
  many.
- **The driver** (`src/main.zig`): `rig build` runs the N `zig build-obj`
  in parallel, then `zig build-exe` on the stub with the objects, and
  reports Zig's errors per unit.

## Decisions for the owner

The owner approved all four defaults on 2026-10-31.


1. **Adopt split builds?** Default: yes, for debug builds, test packs and
   `rig run`, opt-in (`--units N`) for `--release`, while one unit stays the
   default release that Trig is timed with.
2. **Errors across units:** rely on naming every error first in each
   unit's root, checked at start-up (it rests on Zig's undocumented
   numbering order), or have Rig number its own errors? Default: the
   check first, Rig's own numbering only if a Zig release breaks it.
3. **Measure ThinLTO on pup?** It would show whether Linux release
   builds can be split at no run-time cost. Default: yes, as the next
   study, with the same four-build limit.
4. **How to cut:** by the static call graph and a cost model, or by a
   `--pgo` profile's call counts? Default: the static cut first; a
   profile only if the split is ever wanted for timed release builds.

## Not measured

Within the limit of four full Trig builds (the baseline, s4, s8, s8b):
debug builds split; a balanced 8-unit plain cut; 10 or 16 units; the
direct calls and the call-graph cut separately; a rebuild after an edit
to one function; LTO on Linux; Trig's own test suites. The timing machine
was loaded by other sessions' builds throughout.

## Files

- The prototype is kept in the owner's session folder,
  `~/Data/Code/Claude/rig/rig/build-split-study/tools/`, since records
  keep no source: `split.py`, `x.zig`, `build.sh`, `timeit.py`,
  `check-unit.sh`. `split.py PKG OUT N` (with
  `SPLIT_CG=1` for the call-graph cut) over the package that
  `RIG_OUT_DIR=DIR rig build --release` writes.
- `data/build-n1.txt`: today's build, `/usr/bin/time -l`.
- `data/build-s4/`, `data/build-s8/`, `data/build-s8b/`: each unit's and
  the link's `/usr/bin/time -l`, wall times, peak summed RSS, and the
  cut's statistics (`split-stats.json`).
- `data/timing-round{1,2,3}.{json,txt}`: every run's wall time,
  instructions and RSS.
- `data/unit-cost-fit-rows.json`: lines owned per module group and time
  of each unit of s4 and s8, the rows of the balance fit.
