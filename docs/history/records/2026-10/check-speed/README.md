# `rig check` faster and smaller on Trig (2026-10-31)

Queue row 33A, from the compiler review of 2026-10-31 (owner: "Accept all
defaults"). The goal: make `rig check` of Trig faster and smaller with no
change to what it accepts or emits. PR #834. Everything ran on the Mac (M5,
10 cores, 32 GB) with Zig 0.17.0, Trig's `src/` and `tools/trig/main.rig`
at aa3994b, copied once; `rig check --time main.rig` under `tools/low` and
`/usr/bin/time -l`.

## Where the time went

A `sample` profile of `rig check` on main (2e30e8457) put about 48% of its
samples in hash-map work and about 22% in `sema.reachTargets` and its
walks:

- Hashing alone was about 22%: `std.AutoHashMap` runs Wyhash over the
  bytes of every key, and sema's keys are node ids, source positions, type
  ids, and addresses.
- `SemContext.decision`, the memo of `sema.Question`s, was the largest
  table: 5.2M entries on Trig (2.7M about list nodes, 2.5M about leaves),
  72 bytes each, and its growth was 7% of the samples.
- `sema.defaultOrigins` walked what each parameter's type could hold once
  per function and method, 17% of the samples under `computeOrigins`
  alone.

## What changed, step by step

| Step | Check (ms) | Instructions | Peak RSS |
|---|---|---|---|
| main (2e30e8457) | 3,920 | 61.9G | 2.146 GB |
| 1. integer keys hashed by one multiply (`src/fastmap.zig`) | 3,004 | 40.1G | 2.146 GB |
| b. module contexts by id (`sema.ModuleMap`) | 2,996 | 40.0G | 2.146 GB |
| c. what a view could hold, once per pair of types | 2,361 | 26.5G | 2.153 GB |
| a. decisions and expression types by node id | 1,918 | 26.1G | 2.055 GB |
| a'. those arrays sized once; the memo frees its walk | 1,886 | 26.0G | 2.043 GB |
| the compiler on `smp_allocator` (rebased on b0495eb3f) | 1,910 | 26.1G | 0.648 GB |

Check time is the total `--time` reports, the fastest of 5 runs
interleaved across all nine builds, with other agents loading the
machine (load 7 to 10). main at b0495eb3f, which the branch is rebased
on, measures as 2e30e8457 does: 3,869 ms, 61.9G instructions, 2.155 GB.
The branch on b0495eb3f with the arena kept: 1,866 ms, 26.1G, 2.062 GB.
Against main, `rig check` of Trig is 2.0 times as fast (51% less time),
with 58% fewer instructions and 70% less peak memory.

1. **One multiply.** `fastmap.Map(K, V)` is std's table with a context
   that folds each field of the key into a 64-bit hash with Wyhash's mix,
   a 128-bit product whose halves are xored: one `mul` and one `umulh`
   per field. Its low bits, which the table indexes by, and its high bits,
   which it keeps as fingerprints, both depend on every bit of the key, so
   sequential ids and aligned addresses spread. Every
   `std.AutoHashMapUnmanaged` in sema.zig became one: 35% fewer
   instructions.
2. **Module contexts by id.** Module ids run from 1 in the order the
   graph adds them, so the table of contexts is an array. After step 1
   the hash lookup was already cheap: within the noise.
3. **What a view could hold, once.** `viewReachOf(holder, of, from)`
   memoizes `reachTargets` per holder type and target type
   (`TypeMemo.reach`), and the targets themselves per type
   (`view_targets`, `store_targets`). What the parameters of a function
   may store is the union of what each may, and a holder reaches a union
   where it reaches any part, so `defaultOrigins` asks per pair. The memo
   is used only after `computeOrigins` starts, when what types hold no
   longer changes; self-checking builds work out every hit again and
   compare. Resolve went from about 750 ms to 124 ms.
4. **By node id.** A decision about a list node is chained from an array
   indexed by the node's id (`sema.Decided`), in one list in the order
   recorded, which `storage.verifyDecisions` walks; one about a leaf from a
   hash map. An expression's type of a list node sits in an array by node
   id (`fastmap.DenseMap`). Storage went from about 1,015 ms to 620 ms,
   and peak memory 4.5% lower.
5. **The allocator.** The compiler allocated everything from
   `init.arena`, so every buffer a table grew out of, and each module's
   first check after a second replaced it, stayed resident. On
   `smp_allocator` the peak is 648 MB, 70% lower.

## The bug the arena hid

`sema.plainLeaves` appended the type parameters it found on the
context's arena, while its three callers free the list with the
context's allocator. From the arena the free did nothing; from
`smp_allocator` it freed memory the arena owns. `std.heap.DebugAllocator`
found it (an invalid free in `computePlainBits`, on
emit-generic's `$plain` cases); `plainLeaves` now grows the list on the
context's allocator.

With the fix, the compiler built on `DebugAllocator` (safety on, never
deinitialized) checked and emitted all 24,050 programs the suite extracts
(`.zig-cache/rig-tests`: cases, doc examples, probes), Trig, the program
of every std module, and the examples, with no invalid free and no fault,
and emitted the same Zig as main for the emit-diff programs.

## No change to what is accepted or emitted

- `tools/emit-diff` identical after every step, and at the head against
  b0495eb3f: 32 programs, 477 files (examples, bench, std, Trig).
- The full suite green on the rebased head, the oracle with it.
- loco's light gate GREEN (122 runs, 0 differ).
- Trig's light gate was not run: Trig's emit is byte-identical, so it
  would build and run the same binary (the foreman accepted emit-diff in
  its place).

## The allocator and every other command

`rig build --release` of Trig, arena and `smp_allocator` interleaved, 5
each, fresh output directory each: arena 410.5, 438.5, 463.0, 473.0,
507.2 s; `smp_allocator` 451.0, 451.0, 466.4, 473.4, 477.5 s. The medians
are within 0.7%; the spread is Zig's, whose input is the same bytes in
both (LLVM is 440 of the 448 s, docs/history/records/2026-10/build-split/),
on a machine other agents were using. The part that is Rig's, check and
emit, is measured apart: `rig emit` of Trig, interleaved, fastest of 5,
2.82 s with the arena and 2.74 s with `smp_allocator` (medians 3.20 and
3.10 s), at 2.14 GB and 0.65 GB peak. `rig check` alone: 1,866 and 1,910 ms
(medians 2,433 and 2,425).

The suite's wall time with other agents running: jobs 130.8 s with the
arena, 125.1 and 140.3 s with `smp_allocator`.

## What is left

The profile after these steps: `typecheck.readValue`, `sema.handsOverKind`
and `shapeOf`, the remaining memos' lookups, and `_platform_memset`, which
in a safe build is the allocator filling new memory as undefined (most of
it the decisions list growing). Typecheck (about 600 ms) and storage
(about 570 ms) are now the largest passes.
