# What the allocator keeps resident, per heap (2026-11-02)

Measured only. Why Trig's peak RSS at four checkers rose 1-3 MiB with
walk-ahead (trig#245), and what a heap costs in resident memory.

## Walk-ahead holds no more memory

Instrumented Trig 07e4447 and walk-ahead, release, Rig 43e1f65, printing
`os.memory()` (the allocator's live and peak bytes) at the end of loading,
of checker creation, and at exit; `/usr/bin/time -l` for maximum RSS; the
Mac, four checkers, five runs each.

| project | RSS main | RSS walk-ahead | allocator peak, main / walk-ahead (MiB) |
|---|---|---|---|
| zod3 | 106.4-110.9 | 109.8-113.0 | 51.8-52.0 / 51.7-52.1 |
| superstruct | 33.6-34.8 | 33.5-36.0 | 9.9 / 9.8-10.0 |
| mitt | 39.5-41.9 | 44.2-44.8 | 19.2-19.5 / 19.2-19.3 |
| ts-pattern | 271.9-274.2 | 274.0-274.7 | 119.5 / 119.4-119.6 |

The allocator's live and peak bytes are the same within 0.3 MiB. The extra
RSS is pages the runtime keeps resident when more threads allocate at once.
A `vmmap` taken at exit under lldb shows the same footprint for both, since
the debugger changes the timing, so it cannot attribute the extra.

The allocator's count leaves out Trig's Tables, which `alloc.zig` maps
apart from the heaps. Rig - Rust's pup smaps of zod3 at exit (Trig 07e4447,
four checkers) put RSS 106.8 MiB as Tables 34.6 (85% dense), large blocks
39.8 (32.6 live), segments 20.0, the binary's text and rodata about 10, and
stacks.

## A report of each heap at exit

`heap-residency-data/heap-report.patch`, on Rig 43e1f65, measurement only:
`alloc.zig` keeps a list of the heaps it makes, and `os.exit` prints, for
each, its segments, the pages handed out, the pages resident (`mincore`),
the bytes on its free and remote lists, the uncarved rest of each class's
current page, and its large blocks live, kept, and kept resident. On the
Mac it prints when `RIG_HEAP_REPORT` is set; the Linux build links no libc,
so it always prints and uses Linux's own `mincore`. Trig fbc0f8e (main) and
the same with walk-ahead reverted, five runs each at four checkers on the
Mac (`mac-runs.txt`); on pup's E-cores (`hr.sh`, `pup-runs.txt`).

Mac medians, MiB:

| | RSS | heaps | segments resident | free + remote | large live | large kept resident |
|---|---|---|---|---|---|---|
| zod3 main | 108.9 | 10 | 25.3 | 2.4 | 29.9 | 3.5 |
| zod3, walk-ahead reverted | 107.3 | 10 | 25.2 | 2.4 | 29.9 | 3.2 |
| zod3 main, 1 checker | 72.4 | 1 | 14.7 | 0.6 | 24.9 | 2.2 |
| mitt main | 41.6 | 10 | 8.8 | 1.6 | 12.9 | 3.0 |
| mitt, walk-ahead reverted | 40.3 | 10 | 8.7 | 1.4 | 12.9 | 2.0 |
| ts-pattern main | 272.4 | 10 | 43.5 | 3.2 | 80.3 | 19.3 |
| ts-pattern, walk-ahead reverted | 269.2 | 7-10 | 41.8-43.4 | 2.6-3.2 | 80.3 | 18.3 |

pup (x86-64, THP madvise), zod3 at four checkers:

| cores | heaps | segments resident | RSS |
|---|---|---|---|
| 12-15 | 4 | 28.4-30.4 | 102.3-103.8 |
| 12-19 | 8 | 26.8-30.7 | 100.3-104.5 |
| 12-19, `RIG_WORKERS=22` | 22 | 31.4-33.6 | 106.3-107.1 |

1. Segments are dense: free and remote lists hold 7-10% of their resident
   bytes. The uncarved rest of each class's current page is 1.4-2 MiB of
   address a heap, mostly not resident.
2. Workers follow the CPU mask (four cores make four heaps), and every
   worker's heap is touched: the lib parse tasks reach them all. Going from
   4 heaps to 22 adds about 3 MiB of resident segments on zod3, mitt and
   ts-pattern alike, so a heap costs about 0.2 MiB on pup, prefault and huge
   pages included. The growth from one checker to four (14.7 to 25.3 MiB of
   segments on the Mac's zod3) is mostly the checkers' own data.
3. Walk-ahead's 1-3 MiB is not in the segments: it is freed large blocks
   kept resident (0.3-1.0 MiB more) and, on ts-pattern, more heaps touched;
   about 1 MiB is outside the report, likely task stacks.
4. A timed run (four cores, four heaps) carries about 0.8 MiB of heap
   overhead, under 1% of RSS. A run on every core of pup (22 workers)
   carries about 4 MiB: 1.5% of ts-pattern's RSS, 3-4% of zod3's, 9% of
   mitt's.

## The lever left (queue row 63, queued low by the owner)

Run the program's tasks on as many workers as it has checkers: Trig asking
`task.workers(checker count)` at the start of `new_program`, before the
loader's first task (Trig branch `few-heaps`). Built for pup, not measured.
