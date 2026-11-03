# Row 23c: the runtime's variables as cells

Part of split builds (row-23c.md): a program compiled as N Zig units, each
compiling the runtime, must still have one allocator, one scheduler, one
stdout buffer, one panic state per process. This piece makes every
module-level variable of the runtime a *cell*: unit 0 holds it, the other
units reach unit 0's by symbol. Built in `~/Data/Code/worktrees/rig/split-units`,
uncommitted.

## Shape

`src/split.zig` (written beside each program as `rig/split.zig`; main.zig
adds it to both package lists, nothing else):

- `on`, `unit: u32`, `main: bool` from `@hasDecl(@import("root"), "__rig_unit")`
  (one-unit: false, 0, true).
- `cell(comptime v: anytype, comptime name) @TypeOf(v)`: the variable keeps
  its declaration (renamed `x_var`, same type, initializer, alignment);
  `const x = split.cell(&x_var, "file.x")` is a comptime-known pointer used
  in its place (`x.*`, `x.field`, `x.method()`, `x[i]` for arrays,
  `x.*[i]`/`x.*.len` for slices). One-unit: returns `v`. Unit 0 of a split
  build: also `@export`s the variable's bytes as `rig.cell.file.x` (Zig
  refuses to export an auto-layout type, but accepts a `*const [n]u8`
  pointer cast of it). Units 1..N-1: `@ptrCast(@extern(*align(A) [n]u8, ...))`,
  still comptime-known, so no load through a pointer.
- `local(v: anytype, comptime name) @TypeOf(v)` (inline) for thread-locals,
  each reached through a three-line `inline fn x() *T { return split.local(&x_var, "file.x"); }`.
  One-unit: returns `v`. Split: every unit (unit 0 too) uses a slot of one
  exported thread-local block, `rig.locals` (9 slots of 256 bytes,
  64-aligned), defined by unit 0 in split.zig, named in a list there. A
  slot's last byte says whether its thread has set it; the first use copies
  the unit's own `x_var` (its untouched initial value). This handles
  non-zero initializers (`TaskState`, `Waker` hold `ArrayList.empty` and
  `Control`, not all zero bytes).
- Why one block: Zig can export a thread-local only with the `export`
  keyword and a literal name (`@export(&tls)` is "not comptime-known"), so
  one literal block beats one literal per variable.
- Lazy analysis: a unit defines only the variables it refers to, so unit 0
  must refer to every cell. Each file has one `comptime { if (split.on and
  split.main) _ = .{ cells... }; }`; runtime.zig's also names `tasks`,
  `sched`, `net`, `fast_alloc`, so their lists run in unit 0 even if unit
  0's code never touches them. A test in split.zig scans the five files
  and fails if a `split.cell` is missing from its file's list.

## Count

| file | cells | thread-locals |
|---|---|---|
| runtime.zig | 39 (33 top-level; HeapProfile 2, MapTracer 3, Sanitizer 1) | 5 (thread_task, panicking_here, HeapProfile.next/scope, MapTracer.thread) |
| alloc.zig | 23 | 2 (my_heap, my_token) |
| sched.zig | 24 | 2 (me_slot, waker) |
| tasks.zig | 1 | 0 |
| net.zig | 4 (`lent.*`) | 0 |
| total | 91 | 9 |

Left per unit, on purpose: `noneAt(O).none` (never written), unordered.zig's
`Dummy.groups` (read-only sentinel, never compared by address),
`TestErrorGlue.drops` (runtime's own tests only). Left per unit, a
limitation: `HeapProfile.of(T)`'s per-type `Owner` (a generic static: unit 0
cannot define every type's), so a heap profile of a split build may list a
type once per unit. Outside my files: `std/crypto.zig`'s `dit_known` (a
cache; per unit is harmless) and Zig std's own globals (`smp_allocator`'s
state, stderr lock, Linux `elf_aux_maybe`/TLS descriptor; the prototype's
`rigx_stdshare`) belong to the units pass.

Cross-file uses changed: `rt.process.*`, `sched.deterministic.*`,
`sched.seed_value.*`, `fast_alloc.owner_lost.*`; and `std/os.zig`'s
`rig.process.* orelse` (one line outside the brief's file list, needed).

## One-unit identity

Method: emit each program with main's rig (`tools/baseline 43cdd0cc9`,
`build --release`), then build its package by hand with rig's flags
(`zig build-exe -Osafe -fomit-frame-pointer`) twice: as emitted, and with
this branch's runtime files. The hand build of main's package is
byte-identical to main's own binary (`__text` equal), so the comparison is
faithful. scratchpad: `ident/ident.sh`, `compare.py`.

| program | functions | instructions | bodies differing | bytes differing |
|---|---|---|---|---|
| two.rig (alloc, Map, tasks) | 641 | 78678 = 78678 | 0 | 17 `add` |
| bench/tasks/tasks.rig | 656 | 79936 = 79936 | 0 | 17 `add` |
| bench/actors/actors.rig | 664 | 80483 = 80483 | 0 | 17 `add` |
| examples/json_tour.rig | 605 | 74400 = 74400 | 0 | 9 `add` |
| examples/word_count.rig | 588 | 70471 = 70471 | 0 | 9 `add` |
| bench/hash/map.rig | 730 | 93149 = 93149 | 0 | 9 `add` |

Every function's instructions are the same (addresses normalized); `__text`
is the same size. The only bytes that differ are the immediates of
`add x0, x0, #off` that pick a thread-local's TLV descriptor: the runtime's
5 thread-locals sit in a different order in the TLS block
(`__thread_bss` 48 -> 52 bytes, or 25 -> 32), because each is now reached
through an inline accessor. Tried: storage in split.zig, storage in place,
original names kept, one-layer accessor: the order moves with any inline
accessor, and a thread-local's address is not comptime-known, so no
pointer constant can stand for it. No extra load, branch, or instruction.

Shapes rejected on the way, by the same measurement:
- storage inside a generic struct in split.zig (`cell(T, init, name)`):
  Zig gives one type per body and captured values, so two cells with the
  same type and initializer shared one variable (found by a leak note
  printing `rig test` in a `rig run`); fixed by capturing the name, but
- it also typed the six inferred-type vars (`var started = false;`), which
  alone reorders `_MergedGlobals` (4 functions differ in main's own
  runtime when only those six get types): storage now keeps its original
  declaration text.
- cells as inline functions (`x().*`): Zig's inline-call blocks reorder
  basic blocks (12 functions differ, sched.next 403 -> 425 instructions).
- `ptr.len` on a pointer to a slice loads the whole slice (sched.search
  scheduled differently); written `workers.*.len`.

## Two-unit test

scratchpad `two/`: `two.rig` (a Map, tasks of `work` that each fill a List,
`report` that allocates and prints), emitted by main's rig, runtime swapped,
`make2.py` writes unit 0 (main; `fan` and `report` call unit 1 by C-ABI
externs), unit 1 (`fan`, `report`, `work`), and an entry root (its own
`__rig_unit` id 2, `main` calls unit 0's `rig_entry`), each re-exporting
`__rig_main.zig`'s pub consts; `build2.sh` builds both units with
`zig build-obj` in parallel and links. ReleaseSafe and Debug (leak-checked)
both print what the one-unit build prints. Unit 0 defines all 91 cells and
`rig.locals`; unit 1 refers to 40 cells and `rig.locals`. A leak made in
unit 1 is reported by unit 0's checker at exit.

## Suites

Through tools/heavy, in the shared worktree (with the units pass's
uncommitted changes there too): `swarm test/rig.rip` 6857 jobs, 0 died;
`zig build test` green, split.zig's three tests among them (a cell is its
variable, one slot per thread-local, every cell in its file's list; the
last caught a removed entry when tried).
