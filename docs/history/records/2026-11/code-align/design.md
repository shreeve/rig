# Aligning Rig's hot code: the design (Expert B, 2026-11-19)

Read at b7bb1df1d (origin/main). Nothing was built or timed; the numbers
below are read from existing binaries (`bin/rig`, a Trig release build in
`trig-cache/check/builds/dfe64858e3f4b7609218/trig`) and from the
records. What the measurement found is in "On measure.md" at the end.

## The answer in short

Sections 1 to 11 were written before measure.md, from the qsort-mac
README's addresses, which point at a 16 KiB boundary; measure.md shows
the boundary is 4 KiB (s18, s0 moved by exactly 4,096 bytes, is as slow).
The model of section 3 holds with `B` = 4,096; the conclusions below are
final, after measure.md.

The cost is a short inner loop's straight-line hot run crossing a 4 KiB
boundary on the M5; crossing a 32-, 64- or 128-byte line costs nothing.
No means Zig 0.17 offers at compile time prevents it:

- **Function alignment** (16 to 128 bytes) neither causes nor prevents a
  crossing: it redistributes the odds (about L/4096 for L hot bytes at
  any alignment under 4 KiB). measure.md built a placement under
  `align(128)` whose loop crosses and is 16.5% slower; the records' std.json
  trial at `align(64)` was up to 7.8% slower than main's placement
  (2026-10/consolidation/speed-baseline.md). Not recommended.
- **Loop alignment** keeps only loops no longer than the alignment off a
  boundary, and Zig 0.17 reaches it only by finishing Zig's bitcode with
  clang, which in measure.md changed qsort's code (245 instructions
  against 357) and aligned one inner loop. Not recommended on 0.17.
- **Moving the function that holds a crossing loop** removes it (s0, s18,
  s36 and the `align(128)` placement all back to 1.009-1.020 of the
  reference), but only a check after the link knows which, and it cannot
  tell a hot loop from a cold one (twelve of thirteen crossings measured
  cost nothing; a program of Trig's size has hundreds). As a compiler
  feature it would mean a second full compile per release build, aimed at
  loops nothing names hot. Not recommended as a compiler feature.

What is worth having:

1. **The layout check as a tool for boards** (measure.md's straddle.py,
   kept in `tools/`): given a binary and the functions a board times, it
   says whether any of their short inner loops crosses 4 KiB, so a board
   rebuilds or reports that placement instead of reading it as a
   regression. No compiler lines; a tools change needs neither light gate.
2. **The program section on a 16 KiB boundary** on the Mac (one field in
   `keepCodeApart`, section 4.2): the program's code is then laid out by
   the program alone, so a change to the runtime (the #1158 and `spawnIn`
   arms that moved qsort) moves none of it, at any granularity. Makes
   nothing faster; makes runtime A/Bs compare the program's code at
   identical addresses. About 3 lines and one check.
3. Boards keep two or three placements for a change to the compiler or a
   program's own code.

Rejected: function alignment, loop alignment by bitcode, padding written
by emit, function order or a section per function, a Mac order file, a
post-link fix inside `rig build`. x86 waits on measure.md's pup job.

## 1. What Zig 0.17 and its linkers allow

Checked against the installed Zig 0.17.0 (`zig build-exe --help`,
`zig cc --help`, `doc/langref.html`, `strings` of the `zig` binary).

| Means | arm64 macOS (Zig's Mach-O linker) | x86-64 Linux (static, no libc) |
|---|---|---|
| `align(N)` on a function | yes: `FnProto <- fn NAME (PARAMS) ByteAlign? AddrSpace? LinkSection? CallConv? ! TypeExpr`; the langref's test "function alignment" shows `fn derp() align(16) i32`; the alignment is the pointer's (`*align(N) const fn`), not the function type's, so `&f` still coerces to `*const fn` | same |
| Default function alignment | 4 bytes: of `bin/rig`'s 5,042 functions, 2,496 sit at 4 mod 8, 1,287 at 8 mod 16, 635 at 16 mod 32, halving on: 4-byte granularity. A Trig release build's 3,830 program-section functions read the same (1,899 / 948 / 491 / 263 / 229). LLVM sets no preferred function or loop alignment for Apple cores | 16 bytes, loops 16 (LLVM's x86 defaults) |
| A flag for LLVM options (`-mllvm`, `-align-loops`) | none: `build-exe` has no `-mllvm`, and the only LLVM option it exposes is `-fopt-bisect-limit` | none |
| `-falign-loops=N`, `-mllvm X` | `zig cc` has both (clang 22.1.8); a `.bc` input takes them, as `--pgo` compiles one | same |
| `-ffunction-sections` | yes | yes |
| Link order or order file | no `-order_file` (no such string in the binary); Apple's `ld` has one, and `--pgo` already links its counted build with it (`xcrun clang`) | `-T` linker script; `--symbol-ordering-file` exists only inside the embedded lld, not as a `build-exe` flag |
| Post-link layout | none | `rig build --bolt` (src/bolt.zig) |
| Profile | `rig build --pgo` (src/pgo.zig, Apple's tools) | `rig build --pgo` (LLVM 22's tools) |

`-cflags FLAGS --` applies to the positional sources after it, and
`build-exe` takes `.bc` sources, so `zig build-exe -cflags
-falign-loops=32 -- program.bc` may finish and link in one command; a
probe must confirm it (section 11).

## 2. The program section

A build preempted by signal puts every function emit writes in
`linksection(rig.preempt_section)` (emit.zig, the function header at
`if (self.code_section and !inlined)`, and the closure header), plus the
runtime's helpers the program calls through pointers
(`rt.program_section`: `wyhash`, `swap`, `FnRef`'s thunks). The signal
handler stops a task only at a program counter inside it
(`sched.inCode`), and `mustNotBeInCode` panics if the scheduler's code
was inlined there. The runtime finds the section once, as `main` starts
(`sched.findCode`): on ELF by the linker's `__start_rig_text` /
`__stop_rig_text`, or the up-to-eight ranges `bin/rig` writes after BOLT
(`CodeWord`); on Mach-O by `getsectiondata("__TEXT", "__rig_text")`,
after `keepCodeApart` marked the object's section `S_REGULAR` so Zig's
linker keeps it a section of its own.

So the program's code must stay in one named section (or BOLT's
recorded ranges). Padding inside it is harmless: nothing executes there,
and a signal never stops there. Splitting it into a section per function
is not: ELF defines `__start_`/`__stop_` only for a section named as a C
identifier (`rig_text.f` has none), and Mach-O's lookup reads one
section of a 16-character name.

On the Mac the output `__rig_text` follows `__text` (qsort at
0x10005bf10 in a small program: the runtime's code comes first). Its
start is the end of the runtime's code rounded up to its alignment,
which with 4-byte functions is 4 bytes. That is why a one-line change to
`spawnIn` moves qsort.

## 3. What alignment can fix

Let a hot loop be `L` bytes, a function's offset granularity `g` (4 on
the Mac), and a boundary `B` (a 16 KiB page, 4 KiB, a 64-byte line).

- **Unaligned:** the loop crosses some multiple of `B` in `(L - g) / B`
  of builds. qsort's loop is 8 instructions, 32 bytes (0x10005bff4 to
  0x10005c010 inclusive; straddle-gen.py's twin is 8 instructions):
  1 build in 585 for a 16 KiB page, 1 in 146 for 4 KiB.
- **Functions aligned to `A`:** the loop's offset within an `A` block
  is fixed by its function alone. If it fits inside one block it never
  crosses any boundary that is a multiple of `A`, pages included; if it
  crosses a block boundary it does so in every build, and that boundary
  is a page in `A / B` of builds (1 in 256 at 64 bytes). Averaged over
  functions the odds are the same `(L - g) / B`: alignment moves the
  risk from all loops a little to some loops more.
- qsort's loop sits 0xe4 bytes into qsort. At `A` = 64 it occupies bytes
  36 to 67 of a line: across a line in every build, across a page in 1
  in 256 builds, worse than unaligned. At 32 it crosses a 32-byte block
  in every build and a 64-byte line in half.
- **Loops aligned to `A` >= `L`:** the loop starts a block and crosses
  nothing up to the page. This removes the class for every loop up to
  `A` bytes, which are the loops where one fetch boundary is a large
  share of an iteration. A longer loop crosses pages with the same odds
  as before.
- **The program section aligned to a page:** the program's addresses
  modulo 16 KiB depend only on the program's own code. It does not
  protect a loop from the program's own changes (s0-s7 change only
  `main`), but a runtime change, or a std Zig shim's, moves nothing of
  the program's.

The line crossing itself costs nothing on the M5 by the README's data
(five of the seven fast placements cross a line), so function alignment
buys only the stability of a property that does not matter there. If
measure.md shows otherwise (a loop head's offset within 32 or 64 bytes
mattering, as x86's decoded-uop windows can), function alignment becomes
worth its lines for that target.

## 4. Each means: where it lives, what it costs

### 4.1 Function alignment (not recommended now)

If built, it needs no fact: it is a property of every function emit
writes out of line, as the section is.

- **Runtime:** `pub const code_align` in src/runtime.zig beside
  `program_section`, chosen by `builtin.cpu.arch` and `builtin.mode`:
  the target's natural alignment in a debug build (4 on arm64, 16 on
  x86-64, which also leaves split builds, debug by default, unchanged),
  the measured value in a release build. The emitted Zig is the same on
  every target; the runtime decides, as `preempt_section` does.
- **Emit:** the two places that write `linksection(...)` write
  `align(rig.code_align) ` before it, for every function not emitted
  `inline`, in every build (not only preempted ones). Never on an
  `extern` declaration, where `align` would claim something of foreign
  code.
- **Runner:** test/rig.rip's `unplaced` strips `align(rig.code_align) `
  as it strips `linksection(rig.preempt_section) `, so the nine `code`
  cases that pin a function's line keep reading the same.
- **Size:** about `(A - 4) / 2` bytes a function on the Mac. Trig's
  3,830 program-section functions: 115 KB at 64 (1.3% of its 8.9 MB
  `__rig_text`, 0.3% of the 34 MB executable), 54 KB at 32, 23 KB at 16.
- **Lines:** about 15 (two emit writes, the constant, the runner), a
  test, docs. Removed in one step.
- **Cost carried:** every new place emit writes a function header must
  write it too; a forgotten one costs only stability, and the check in
  section 7 catches it.

A narrower variant, aligning only functions that hold a loop, needs a
fact: a set `loop_holders` in `SemContext`, decided in inlining.zig
(which already walks every body and knows which callees are emitted
`inline`), read as `Facts.holdsLoop(name)` like `hasEntryCheck`. It is
weaker than it looks: LLVM inlines functions Rig emits plain `fn`
(loops arrive in functions the fact does not name), and a short hot
callee without a loop is not covered. About 40 lines more. Only if the
size of the uniform rule fails.

### 4.2 The program section on a page boundary, Mac (recommended)

- **Where:** `keepCodeApart` (src/main.zig), which already rewrites the
  `__rig_text` section header of each object before Zig links it, sets
  its alignment field (`section_64.align`, a power of two) to 14. Every
  kept-apart link takes it: `buildApart`, `buildSplit`'s units, the
  test driver's build, and `--pgo`'s two links (`Build.apart`).
- **Effect:** the output `__rig_text` starts on a 16 KiB boundary, and
  the program's code is laid out by the program alone.
- **Cost:** at most 16 KiB of padding in `__TEXT`, in the file too.
  About 3 lines and a check (section 7). Nothing at run time.
- **Not covered:** a build not preempted (a program that makes no task,
  or a local task) has no `__rig_text`; its code shares `__text` with the
  runtime's. Giving every Mac release build a program section would put
  every one through `build-obj`, `keepCodeApart` and a `.dSYM`: not
  worth it for boards alone.
- **ELF:** Rig links with no object rewrite there. The same effect would
  take a 4 KiB-aligned anchor in `rig_text` (the section takes its
  largest member's alignment) or a linker script. Not before a pup job
  shows page-crossing loops cost on x86.

### 4.3 Function order, a section per function (rejected)

Zig writes functions into the LLVM module in its own analysis order, so
emit's order does not set the layout, and no order fixes an offset
anyway. A section per function (`-ffunction-sections`, or a
`linksection` per function) breaks the one-section contract of
section 2; a linker script that gathers `rig_text.*` back in a chosen
order exists only on ELF, replaces the static executable's default
layout, and needs a profile to know the order, which BOLT already has.

### 4.4 Loop-head padding written by emit (rejected)

The only way emit could pad a loop is an inline `asm volatile
(".p2align 5")` at its head. Three faults: LLVM places blocks after
emit (a rotated loop puts the padding inside the body, run every
iteration); LLVM counts an inline-asm directive as one instruction when
it relaxes branches, so padding of up to 60 bytes can push an arm64
`tbz`/`cbz` (+/-32 KiB) out of range, an assembler error that breaks
"accept means correct"; and a volatile asm statement in every loop
constrains the optimizer. Post-processing Zig's `-femit-asm` has the
same branch-range fault.

### 4.5 Loop alignment by LLVM: the bitcode finish (draft, owner's call)

LLVM pads loop heads itself and accounts for the padding when it relaxes
branches, so this is the sound way to align loops. In 0.17 it is reached
only through clang:

1. `zig build-obj FLAGS root.zig -femit-llvm-bc=program.bc -fno-emit-bin`:
   Zig's own optimized module (its pipeline, its loop vectorizer off).
2. `zig cc -target T -mcpu=native[+reserve_x15] -c -O3 -Xclang
   -disable-llvm-passes -falign-loops=N [-fno-PIC -fno-PIE]
   program.bc -o program.o`: code generation only, with the loops
   aligned. The function attributes Zig wrote (frame pointers, stack
   probes, the processor's features) travel in the bitcode; the target
   machine's flags are pgo.zig's, shared, not copied.
3. On the Mac, `keepCodeApart`; then `zig build-exe ... program.o` as
   `buildApart` links today (Linux: with `--emit-relocs` for `--bolt`).

- **Where:** a step of its own beside pgo.zig, sharing pgo.zig's clang
  flags (`target`, `position`, the reserved register), so the two cannot
  drift; `buildApart` on the Mac already compiles to an object first, so
  the step slots in there. Release builds of one unit only.
- **Cost:** about 150 lines; every release build runs Zig, writes the
  bitcode, and runs clang's code generation (some seconds on Trig with
  debug information; `--strip` makes the bitcode small); every flag Zig
  takes that bears on code generation must reach clang too, a parity to
  keep on each Zig upgrade.
- **Size:** a Trig release build has 43,912 distinct backward-branch
  targets in `__rig_text` (119,904 backward branches), about 44,000 loop
  heads. LLVM skips loops colder than their function's entry, so fewer
  are padded; at 32 bytes the upper bound is about 615 KB (6.9% of the
  program's code), at 64 about 1.3 MB, at 16 about 260 KB.
  `-mllvm -max-bytes-for-alignment=12` bounds the padding at the price of
  leaving some loops unaligned.
- **Executed cost:** the padding before a loop head runs once at each
  entry from the block before it; an inner loop entered from a hot outer
  loop pays it every outer turn.
- **Bar:** a speed feature, so it lands only on Trig's bar (more than
  1.5% faster, or at least 1% fewer instructions on one checker, peak
  memory no higher, the executable's own growth excepted), and std.json,
  the hash tables and std.text within 2% of their guards. The json
  trial of 4.1 is the warning: one alignment was faster on some files and
  up to 7.8% slower on others.

### 4.6 BOLT (unchanged)

`--bolt` moves the profiled program functions into new sections, orders
them (`-reorder-functions=cdsort`), lays out their blocks
(`ext-tsp`), and aligns what it moves by its own `-align-functions`
(64 by default, with a cap on the bytes it pads; confirm with `llvm-bolt
--help` on pup). It supersedes static alignment for every function the
profile names; `seal`'s ranges are unaffected by padding. Function
alignment (4.1) and loop alignment (4.5) survive into the linked input
BOLT reads; neither needs a change there.

### 4.7 A Mac order file (rejected)

Zig's Mach-O linker has no `-order_file`. Using Apple's `ld` for every
Mac release (as `--pgo`'s counted build does) to gain one would make
Xcode's tools a requirement of `rig build`, and an order needs a profile
to know what is hot. An order also cannot fix an offset.

### 4.8 PGO

The function `align` attribute is in the bitcode `--pgo` compiles, so
4.1 carries over unchanged. Loop alignment would be one flag in pgo.zig's
`cc` (`-falign-loops=N`), and should be added only with 4.5, so a
`--pgo` build and a plain one align alike.

**A finding outside the brief.** `--pgo` compiles Zig's unoptimized
bitcode with clang's `-O3`, whose pipeline runs LLVM's loop vectorizer.
Zig 0.17 turns it off for every build it optimizes
(`PipelineTuningOptions.LoopVectorization = false`; llvm-project#186922
miscompiled the Zig compiler itself; INTERNALS, "LLVM's loop vectorizer
is off"). So a `--pgo` build runs a pass every other Rig build avoids
because it miscompiles. The PGO owner should pass `-fno-vectorize` to
clang, or show the build sound with it on.

## 5. Facts

None of the recommended means needs one. Function alignment and the
page-aligned section are uniform: emit writes one spelling for every
out-of-line function, as it writes the section, and the runtime's
constant chooses the number. Loop alignment lives entirely in the build
(main.zig and the finishing step), after emit. The only fact a design
here would need is `loop_holders` for the narrow variant of 4.1.

## 6. Split builds, frames, debug information

- **Split builds:** each unit's object carries its own `__rig_text`; with
  4.2 each unit's section is page-aligned, so a split build pads up to
  16 KiB a unit (debug builds, by default only those split). With 4.1 a
  cut function's early call into its owner is aligned like any other.
  `rig.split.exportFn` takes `&f`, which coerces.
- **frames.zig** reads a function from its symbol to the next; padding
  between functions is read as the end of the one before, and holds no
  stack adjustment (arm64 padding is `nop` or zero words, x86 `nop` or
  `int3`), so no frame changes.
- **dSYM:** unaffected; `keepCodeApart` changes only the alignment field.

## 7. Tests

- **4.2:** test/cli/preempt_section.sh already builds bench/tasks and
  bench/actors natively on the Mac and reads `__rig_text` with LLVM's
  `objdump`. Add one check there: the section's address (`objdump -h`) is
  a multiple of 0x4000. No new build, so the suite's time does not grow.
- **4.1, if built:** a `code` case whose regex argument matches
  `fn f\([^)]*\) align\(rig\.code_align\)` (regex arguments read the raw
  emitted Zig, before `unplaced`), and one that an `extern` declaration
  has none; in the same script, every function symbol in the program
  section is a multiple of the release `code_align`.
- **4.5, if built:** a CLI script builds a program whose hot function
  holds one loop, finds the target of the backward branch with
  `objdump -d`, and checks it is a multiple of N; it also runs the
  program, so the finished build is shown to run. test/cli/pgo.sh keeps
  covering the shared flags.
- Each is sanitizer-clean by construction (layout only); the suite's
  doc examples and `code` cases are unaffected apart from the runner's
  strip.

## 8. What every later change carries

| Means | Lines | Carried by later changes |
|---|---|---|
| 4.2 page-aligned section (Mac) | ~3 + one check | nothing: one field in a function that already rewrites the header |
| 4.1 function alignment | ~15 + tests | every new function header in emit writes it; the runner strips it |
| 4.1 narrow (loop holders) | ~55 + tests | a fact to keep right as inlining changes |
| 4.5 bitcode finish | ~150 + a script | two release pipelines; clang's flags kept in step with Zig's on every upgrade; slower release builds |

## 9. What stays the user's choice

`--bolt` and `--pgo` (each needs a workload and a machine for it), and
`--strip`. Alignment, if any, has one value per target and no flag, as
preemption has one way per target.

## 10. Decision by what measure.md finds

| measure.md finds | Then |
|---|---|
| The page boundary is the cause (line crossings free, as the README's addresses say) | 4.2 now; 4.5 as a draft measured on Trig; no 4.1 |
| A loop head's offset within 32 or 64 bytes matters on the M5 | 4.2; 4.1 at the smallest value that removes it, if Trig, json and the guards stay within their rules; 4.5 still the only full fix |
| Neither explains s0 | 4.2 (it still makes runtime A/Bs honest); boards keep two or three placements |

For every case, boards keep two or three placements of each arm for a
change to the compiler or to a program's own code; with 4.2, a
runtime-only A/B on the Mac compares the program's code at identical
addresses and needs one.

## 11. What a builder probes first

1. Zig's Mach-O linker honors an input section alignment of 2^14 for
   `__rig_text` (`otool -l`: the output section's `addr` and `align`).
2. `align(rig.code_align)` compiles on every function shape emit writes:
   generics, methods, closures, a function returning `type`, a cut
   function, `main`.
3. clang's `-falign-loops=N` takes effect on a `.bc` input (it sets a
   target-machine option, not a function attribute; `-falign-functions`,
   which clang applies while generating IR from C, would not), and
   `-Xclang -disable-llvm-passes` leaves Zig's optimized module as it is.
4. Whether `zig build-exe -cflags -falign-loops=N -- program.bc` finishes
   and links in one command.

## On measure.md

**Which row of section 10.** The first, with the boundary corrected:
line crossings are free, and the cost is a 4 KiB crossing, not 16 KiB.
So 4.1 is out (measure.md shows directly that an aligned placement can
cross and is 16.5% slower), and 4.2 stands: it makes the program's
addresses modulo 16 KiB, hence modulo 4 KiB, independent of the runtime.

**4.5, the bitcode finish, is weaker than section 4.5 hoped.** measure.md's
probe (probes/bcbuild.sh) compiled Zig's optimized bitcode with `zig cc
-O3 -Xclang -disable-llvm-optzns -falign-loops=64` and got qsort in 245
instructions against 357. Its clang line passes neither `-target` nor
`-mcpu=native+reserve_x15`, which pgo.zig's does, so part of the
difference may be that; either way it shows that the finish is a second
code generator whose parity with Zig's must be proved, not assumed. And
LLVM aligned one inner loop of qsort, not the partition loop: its block
placement skips a loop head entered by a hot fall-through or colder than
the function's entry. A loop of 40 hot bytes would also need an
alignment of 64 to be safe, at the size cost of section 4.5. Rejected on
Zig 0.17; worth a look if a later Zig passes `-align-loops`, and then
only if a check like the one below shows it clears the loops that matter.

**The post-link fix, as a compiler feature.** measure.md's fix moves the
function that holds a crossing loop. In `rig build` that would be:

1. link; read the program section (as frames.zig reads it, and
   straddle.py does) for inner loops of at most a few hundred bytes whose
   hot run crosses 4 KiB;
2. record the functions found as a fact for emit (`align(P)`, P the next
   power of two of the function's size, so it lies in one 4 KiB block),
   emit again and compile again;
3. link and check again, since every function after a moved one moves
   too, until no named loop crosses.

Each round is a full Zig compile of the program (minutes for Trig), so
it doubles or triples a release build. Mach-O gives no cheaper lever:
`keepCodeApart` can rewrite a section's header, but a function's place
inside the section is fixed by the object's offsets and relocations, and
Zig's linker takes no order file. And the check cannot tell hot from
cold: at Trig's 44,000 loop heads and tens of bytes a loop, a few hundred
short loops cross 4 KiB in any build, nearly all harmless (twelve of the
thirteen crossings measure.md timed cost nothing). Aligning all of them
to their size would pad by up to 4 KiB each. A profile could name the hot
ones, which only `--pgo` has, and `--pgo` already compiles twice; aiming
its second compile at the profile's hottest crossing loops is the one
place the fix could pay. It is a speed feature for `--pgo` alone, to be
measured on Trig against the bar if anyone proposes it, not part of this
round.

**The check as a tool.** What the check does well is tell a board that a
placement is bad for the function it times. Kept as `tools/straddle BIN
[FUNC...]` (measure.md's straddle.py: LLVM's objdump over `__rig_text` or
`rig_text`, backward branches of at most 256 bytes whose span crosses
4 KiB, by function), a board can name its hot functions and rebuild an
arm whose loop crosses, or report it beside the row. That replaces the
median of placements for a known hot loop, costs the compiler nothing,
and needs neither light gate. It belongs with the other timing tools
(tools/mac-claim, tools/low), with a test/cli script that runs it on a
synthetic object holding one crossing loop and one clear one.

**x86.** measure.md's pup job (probes/pup-job.sh, loopgen-x86.py) asks the
same question on Meteor Lake. Nothing here changes Linux until it
answers; if a 4 KiB crossing costs there too, the same tool applies to
`rig_text`, and 4.2's ELF form (section 4.2) becomes worth weighing.

**What changes in the recommendation.** Function alignment moves from
"not now" to rejected; loop alignment from "draft" to rejected on Zig
0.17; the post-link check is added, as a tool for boards and not a
compiler pass; the page-aligned program section on the Mac stays.


The owner approved the defaults above on 2026-11-19 ("Approve the defaults").
