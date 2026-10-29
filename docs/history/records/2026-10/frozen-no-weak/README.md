# A frozen value's allocation has no weak count (#767, 2026-10-28)

The owner, 2026-10-28, approving the keep-or-cut panel's defaults: "`*Frozen` drops its weak count", and "measure what the weak count costs every `*T` on Trig, by share first, before changing how weak counts are stored. Measure only."

## What was built

A `*Frozen[T]` can have no weak handle. SPEC ("Frozen values") says "A frozen value has no weak handle"; `~f` of a `*Frozen` (`frozen has no weak handle`), of a `*{A + Syncs}` (`apis object shared no weak handle of a frozen value`), a `~{A}` whose API syncs, and a generic `~T` given a frozen value's handle (`frozen as an inferred type argument`) are all rejected. The runtime's `weakErased`, `weakDropErased` and `upgradeErased` are `unreachable` for a frozen holding. So the weak count of a frozen value's allocation was written once, at 1, and taken back once, at the last drop, and never read otherwise.

`Counted(T, is_frozen)` in src/runtime.zig is now:

| | strong | weak | value | last drop |
|---|---|---|---|---|
| `Shared(T)`, behind `*T` | `usize` | `usize` | `T` | the strong decrement, the value's drop, then the weak decrement, which frees the box when it reaches zero |
| `Frozen(T)`, behind `*Frozen[T]` | `usize`, atomic | `void` | `T` | one atomic decrement (`acq_rel`), the value's drop, and the free |

`Frozen(i64)` is 16 bytes, where it was 24; any value aligned to 8 or less saves 8 bytes, and the allocator's size classes are 8 bytes apart up to 64, so the saving is real for every small frozen value. `weakRef` on a frozen allocation is a compile error. The layout is the runtime's alone: emit already wrote `rig.Frozen(T)` and `rig.frozen(v)`, so it decides nothing new, and no storage or facts decision changed. A `*T` is unchanged.

Cases: the runtime unit test "a frozen value's allocation has no weak count" (it failed first, `expected 16, found 24`), and `frozen dropped once by many tasks` (`seeds: 20`): five tasks each drop a handle in the order the schedule picks, and the value's `drop` runs once, with no leak.

## Gates

- `swarm test/rig.rip all -w 6` on the Mac: 10,807 jobs, none died.
- `zig build test` on pup at `-Doptimize=debug`, `safe` and `fast`: all pass.
- Trig's light gate (`PUP_RIG=/zfs/trig-pup/rig-frozen/bin/rig tools/light`, Trig main 2ba0719): GREEN in 49 s.
- loco's light gate: GREEN (7 unit tests, 51 checks, 122 runs identical to the Rust loc).
- std.json's guard: all six files within 0.7% of `guard.txt`, each with fewer instructions.
- The Map guard: the third run within 2% on every case. The first two each flagged one different case (hashmap text-miss 2.1%, then hashmap pair-hit 2.4% more instructions), and main's own run flagged none; no bench/hash program makes a frozen value, so the runtime code they run is the same.
- Runtime benches, base main de6ef3e41 and the branch interleaved, best of two rounds: no bench makes a frozen value, and every figure is within the noise on both machines (rows in each PROGRESS.md). On pup, everything ran on core 6 with core 7 idle, so the http server and its load generator shared core 6, and every figure there is lower than the rows taken on cores 6 and 7.

## The measurement: what the weak count costs every `*T` in Trig

Trig at main 2ba0719, built `--release` with a Rig that counts (a scratch patch, not landed): each `rig.shared` call (the only maker of a `Shared(T)`: every `*T` made from a value, and every shared closure), its bytes, each last strong drop (where the second decrement runs), and every allocation through the release allocator. On pup, `trig -p tsconfig.trig.json --noEmit`:

| Project | Checkers | `*T` allocations | their bytes | last drops | all allocations | all bytes |
|---|---|---|---|---|---|---|
| ts-pattern | 1 | 1 (a shared closure) | 40 | 1 | 3,427,842 | 246.0 MB |
| ts-pattern | 4 | 1 | 40 | 1 | 3,633,991 | 272.0 MB |
| zod3 | 1 | 1 | 40 | 1 | 566,301 | 79.8 MB |
| superstruct | 1 | 1 | 40 | 1 | 217,880 | 24.5 MB |

Trig names `*T` in a handful of places outside its tests (`*Cell` twice, `*Chan` twice, and a shared closure), each a handle made once; its stores are `Table`s, `List`s and Maps, which hold no count. One `*T` allocation in 3.4 million is 0.00003% of allocations and 0.00002% of bytes. The weak count costs that allocation 8 bytes; the second decrement runs once a run, a decrement in memory and a branch (the initial store of the count is one more), so under 10 instructions of the 9.12 billion user-mode instructions this build retires on ts-pattern at one checker (`perf stat -e instructions:u`, pup core 6). Nothing a different storage of the weak count could save on Trig is measurable.

**Verdict: no.** Storing the weak count only when a weak handle exists is not worth a design round on Trig's evidence: Trig makes one `*T` a run. A program built of `*T` graphs could gain up to 8 bytes and one decrement per allocation, but no program we measure is one, so the question waits for one that is.
