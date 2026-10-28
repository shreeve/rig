# mimalloc as Rig's allocator: the ceiling and what it would take (2026-10-28)

The owner asked whether Rig could use mimalloc. This record measures
Trig with mimalloc 3.5.3 in place of Rig's release allocator
(`src/alloc.zig`), beside glibc's `malloc` and beside alloc.zig with
libc linked, which separates libc's own cost from the allocator's, and
lists what a real integration would take
([feasibility.md](feasibility.md)). Nothing here changes Rig.

## Builds

Every variant is Rig main `1d0f4dc58` and Trig main `403a823`, built
with Trig's normal release build (`rig build --release`, no PGO) on
pup cores 0,5 through `/zfs/trig-pup/trial/slot.sh`
(`TRIG_RELEASE_SLOTS="0,5 0,5 0,5"`):

| variant | Rig's release allocator | libc |
|---|---|---|
| (a) main | alloc.zig | none |
| (b) mimalloc | mimalloc 3.5.3 (`alloc-mimalloc.zig`, its `static.c` built by Zig's C compiler, `-O3 -DNDEBUG`, no C sanitizer) | glibc, dynamic |
| (c) malloc | glibc `malloc` (`std.heap.c_allocator`, `alloc-libc.zig`) | glibc, dynamic |
| (d) libc | alloc.zig | glibc, dynamic, unused by the allocator |

(b) and (c) replace `src/alloc.zig` with a shim before `zig build`;
`zig-wrap.sh`, run as `ZIG`, adds `-lc` (and for (b) mimalloc's C file)
to the program's `zig build-exe` (`build2.sh`). mimalloc runs with its
defaults. Every variant printed the same output in every run.

## Trig on pup

`measure.py 20`: ts-pattern and zod3 at one checker, core 6 with its
sibling 7 idle, 20 rounds, the four builds interleaved and the order
reversed every other round, under `perf stat`; fastest wall with the
median beside it, fewest instructions and cycles, median dTLB misses,
peak RSS by `/usr/bin/time` ([trig-mi.md](trig-mi.md)).

| project | build | wall s | median | instructions | user cycles | kernel cycles | faults | dTLB misses | RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | (a) main | 0.960 | 0.992 | 9,286.3M | 3,911.6M | 334.6M | 39,907 | 1.62M | 271.6 |
| ts-pattern | (b) mimalloc | 0.983 | 1.014 | 9,674.5M | 4,033.8M | 312.6M | 33,326 | 0.32M | 323.4 |
| ts-pattern | (c) malloc | 1.055 | 1.114 | 9,904.9M | 4,245.3M | 427.6M | 65,264 | 2.39M | 260.4 |
| ts-pattern | (d) libc | 1.004 | 1.059 | 9,752.9M | 4,070.8M | 334.8M | 39,957 | 1.60M | 275.8 |
| zod3 | (a) main | 0.196 | 0.207 | 1,684.5M | 707.5M | 89.9M | 9,317 | 148K | 84.7 |
| zod3 | (b) mimalloc | 0.198 | 0.209 | 1,759.1M | 745.8M | 88.9M | 7,265 | 57K | 114.0 |
| zod3 | (c) malloc | 0.217 | 0.226 | 1,811.9M | 797.0M | 109.7M | 18,714 | 272K | 80.7 |
| zod3 | (d) libc | 0.203 | 0.210 | 1,768.1M | 746.2M | 91.5M | 9,369 | 147K | 88.9 |

Against (a), main:

| variant | ts-pattern wall | zod3 wall | instructions | peak RSS |
|---|---|---|---|---|
| (b) mimalloc | 2.4% slower | 1.0% slower | 4.2% / 4.4% more | 19.1% / 34.6% higher |
| (c) malloc | 9.9% slower | 10.7% slower | 6.7% / 7.6% more | 4.1% / 4.7% lower |
| (d) libc | 4.6% slower | 3.6% slower | 5.0% / 5.0% more | 1.5% / 5.0% higher |

- **libc costs 4-5% by itself.** (d) runs the same allocator as (a) and
  executes 5.0% more instructions on both projects, its kernel time
  and faults unchanged: glibc's start code, thread-local storage, and
  the calls Zig's library makes through it. The PGO spike measured
  5-7% for the same link (perf-stage/pgo.md).
- **mimalloc against alloc.zig, both with libc** ((b) against (d)): 2.1%
  faster on ts-pattern and 2.5% on zod3, with 0.8% and 0.5% fewer
  instructions, 6.6% fewer kernel cycles on ts-pattern, 16.6% and 22.5%
  fewer faults, and 80% and 61% fewer dTLB misses, at a peak RSS 17.3%
  and 28.2% higher. Against Rig as it ships, (a), the libc it needs
  leaves it 1.0-2.4% slower.
- **glibc's malloc** is 5-7% slower than alloc.zig beyond libc's cost
  ((c) against (d)), with twice the faults on zod3, and its peak
  memory 4.1-4.7% below main's.

So no allocator measured is a ceiling above alloc.zig as Rig builds
today: mimalloc's gain is smaller than the cost of the libc it needs,
and it buys that gain with a fifth to a third more memory.

## Where mimalloc's gain comes from

- **Huge pages over its arenas.** mimalloc 3 maps its memory in arenas
  and, on Linux, advises each `MADV_HUGEPAGE` (`allow_thp`, on by
  default; `prim/unix/prim.c`). Sampled 0.75 s into ts-pattern, its
  process held 166 MB of `AnonHugePages` of 294 MB resident, against
  alloc.zig's 43 MB of 258 MB. That is the 61-80% fewer dTLB misses,
  most of the fewer faults, and most of the higher peak RSS, since a
  huge page commits 2 MiB as it is touched. alloc.zig already advises
  the segments of a heap that faults in ahead (alloc-seg-thp/), and that
  record measured advising every segment raised peak memory 1.9-9.0%;
  advising its large blocks below 16 MiB raised it too (alloc-thp16/).
  mimalloc takes the trade alloc.zig was measured not to take.
- **Empty pages go back for any size class.** A mimalloc page that
  empties returns to its arena and serves the next page of any class;
  alloc.zig's pages stay with the class that first took them, so a
  program whose sizes change takes new segments (alloc-grow/, the
  `big16` row's kernel time). A port of that is the one technique here
  that could save memory as well as time; it costs a count per page on
  every free.
- **Eager commit.** Its arenas commit on demand in large steps
  (`arena_eager_commit`), so it faults less often; alloc.zig's
  `prefault` does the same for the heap that does the program's work.

## Verdict

1. mimalloc cannot run in Rig's runtime as it is: it needs libc, which
   alone makes Trig 4-5% slower. A no-libc mimalloc means writing its
   21 system primitives in Zig and compiling it against headers with no
   libc behind them: a port.
2. Even with libc's cost set aside, mimalloc is 2.1-2.5% faster than
   alloc.zig on Trig only by huge pages that raise peak memory 17-28%,
   a trade Rig's records measured and declined.
3. Recommended default: keep alloc.zig, and do not pursue mimalloc. The
   one technique worth porting is returning empty small pages to the
   segment for any class, measured on its own.

## Files

- `alloc-mimalloc.zig`, `alloc-libc.zig`: the shims put in place of
  `src/alloc.zig` for (b) and (c).
- `zig-wrap.sh`: the `ZIG` that links libc and mimalloc's C file.
- `build2.sh`: builds a variant's Rig, then Trig with it, on pup.
- `measure.py`: the 20-round Trig harness (alloc-seg-thp/'s).
- `trig-mi.md`: its output.
- `feasibility.md`: what a real integration would take.
