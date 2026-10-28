# The runtime's proven checks, left out (2026-10-28)

**Question.** check-bisect.md §6 measured that turning off all of Zig's
safety checks in the runtime's own Zig (`rig/runtime.zig`, `alloc.zig`,
`table.zig`, `sched.zig`, `tasks.zig`, `net.zig`) takes 1.66% of Trig's
instructions on ts-pattern and 1.34% on zod3, over the instruction bar.
Which runtime sites carry that, and how much of it can be taken soundly:
only checks an invariant the runtime itself keeps proves, never a test of
anything a program controls?

**Answer.** Fourteen small blocks in three files take all of it: Trig
retires **1.66% fewer instructions on ts-pattern and 1.35% fewer on
zod3** in plain release builds (as many as the whole-runtime variant,
1.66% and 1.34%), and **1.71% and 1.07% fewer with PGO**; its `.text`
is 2.2% smaller. Time, 20 interleaved rounds on a quiet machine: plain,
**0.83% and 1.38% faster** (1.05% and 2.25% fewer user cycles); PGO,
**1.23% and 0.52% faster** (1.93% and 0.04% fewer user cycles). That
clears Trig's bar by instructions (at least 1% fewer on one checker; here
on both, in both builds) and not by time (more than 1.5% faster). Peak
memory is lower in the plain builds (0.08% and 0.46%); with PGO it is
0.20% and 0.69% higher, all of it the executable's resident pages (the
PGO build's `.text` is 1.9% larger; anonymous memory is the same to
within 0.2%), which the bar excepts. Every output was main's, byte for
byte, in every round.

Most of the share is not the checks' own compare and branch. The checks'
jumps and compares that execute in runtime code are only 0.20% and 0.18%
of the instructions (PEBS samples, below); the rest of the 1.7% is what
the checks cost around them, in their callers: their panic paths, the
registers and stack they keep live, and LLVM's inlining of the helpers
into thousands of call sites, which the checks made larger. So the sites
were ranked by where Zig's checks sit in the runtime's code, executed and
written, and covered whole.

## The blocks

Each is written as `List.push` and `provenOffset` already were, with a
comment naming its invariant. `proven_checks` (runtime.zig, and its twin
in alloc.zig) is true in a debug build only: there Zig's checks stay in
every block, and `invariant` asserts the fact as well.

| file:line | where | form | the invariant that proves it |
|---|---|---|---|
| src/runtime.zig:2993-2995 | `ListOf.items`, an inline List | read through `mem().ptr` | `len <= mem().len` |
| src/runtime.zig:3029 | `ListOf.grow` | `buf.len *| 2` | none needed: a saturating double, and `reallocSlice` refuses past `max_len` |
| src/runtime.zig:3106-3111 | `ListOf.pop` | `-%= 1`, read through `.ptr` | `0 < len <= buf.len` |
| src/runtime.zig:3155-3159 | `IntoIter.next` | read through `.ptr`, `+%= 1` | `next_index < len <= buf.len`; `len <= max_len` |
| src/runtime.zig:2786-2794 | `FnRef.ctxAs`, the three thunks | `@setRuntimeSafety(proven_checks)` on the cast | `ctx` is the pointer `of`, `ofFn`, or `ofClosure` stored beside that thunk, made from a `P` |
| src/runtime.zig:3439-3445 | `String.appendBytes` | the same, and `@memmove` | both sides are `bytes_.len` long, room just made; a move is right even on overlap |
| src/runtime.zig:3448-3456 | `String.copyFresh` (`ofShort`, `clone`) | the same | `dst` was just allocated at `src.len`: the lengths match, and nothing else overlaps it |
| src/runtime.zig:3889-3892 | `at` | the same | `idx < items.len` by `index` just before |
| src/runtime.zig:3898-3901 | `elemPtr` | the same | the same |
| src/runtime.zig:4206-4209 | `swap` | the same | `a, b < items.len` by `index` |
| src/runtime.zig:5447-5455 | `heldBytes` (`freeSlice`, `reallocSlice`) | `len *% size` | every block freed or regrown was made by `allocSlice` or `reallocSlice`, which tested `len * size` (`std.math.mul`); the callers are the runtime's own (List, String, Table, Map and Set) |
| src/table.zig:189-192 | `Table.push` | `@truncate` for `@intCast` | `len < n` past the full test, since only `push` raises `len`; `n - 1` fits `Index` |
| src/alloc.zig:796-802 | `segmentOf` (`free`, `freeSmall`) | `@setRuntimeSafety(proven_checks)` | segments are aligned to their size and no block is in a segment's first page, so the address is not zero |
| src/alloc.zig:806-812 | `blockOf` (`free`, `freeSmall`) | the same | every class size is a multiple of 8, carved from aligned pages: aligned for `Block` |

Left checked, though the static census lists them: `table.zig:196`
(`self.len += 1` in `push`, 836 sites; only the cast lines of table.zig
were in scope); `String.ofShort`'s `buf[0..w.end]` (509 sites, a fixed
writer's own invariant, which is std's); `allocSlice`'s `@alignCast` of
what the allocator returns (the allocator interface's contract); the
`@call` line of `FnRef`'s thunks (149 sites); std's Wyhash
(`hashBytes`). None is hot. `List.popAt` (#755), `Table.reserve`, emit,
sema, and proofs are not touched.

A failing test first was not possible: a broken invariant (a List with
`len > buf.len`) already panics in a debug build of main, by Zig's
check, and still does on the branch, by that check and by `invariant`.
The Zig unit tests and the suite run the blocks in every mode.

## Finding the sites

- **The record's variant.** check-bisect's `zig-rt` binary (Zig's
  safety off in every function of the six files) and its `main`, on
  pup, against Trig 403a823 emitted by Rig 773978d1d (whose `src/` and
  `std/` are main's at 9f05d492e).
- **Profiles** (`recp.sh`, `sym.py`, `diff.py`). User instructions,
  PEBS (`cpu_core/instructions/upp`, every 10,000,019, the kernel's cap
  of 1,000 samples a second), 250 runs of ts-pattern and 1,200 of zod3
  on core 6: 231,000 and 200,000 samples. Each sample's inline frames
  (`addr2line -i`) attribute it to the innermost frame in a runtime file.
  `main` against `zig-rt` by function (`prof/main-vs-zigrt.txt`): the
  totals differ by 1.62%, matching the counts, but by function the
  difference is spread and partly moved: identical code (`alloc`'s fast
  path disassembles the same in both) reads hundreds of samples apart,
  so per-function sample counts mostly rank layout, not checks.
- **The checks themselves** (`checks.py`). A check is a conditional jump
  that reaches a call of one of Zig's panic handlers
  (`debug.FullPanic.*`) through a few straight-line instructions or a
  `jmp`, its target or its fall-through. Main holds 67,259 such jumps;
  11,360 of them (17%) are written in the runtime's files
  (`prof/main-static.txt`): String's `@memcpy` tests (`ofShort` 1,527,
  `appendBytes` 1,224, `clone` 1,002), `freeSlice`'s byte count through
  `sliceAsBytes` (about 3,500 over its instances), a table's `push`
  (844 cast, 836 add), `IntoIter.next` 202, `pop` 159, `FnRef` 308,
  `grow` 105. Executed (the samples at the jump and at a `cmp`/`test`
  just before it, `prof/main-dynamic.txt`), they are 0.20% of ts-pattern's
  instructions and 0.18% of zod3's: `grow`, `Table.push`, `pop`,
  `items`, `freeSlice`, `ofShort`, `FnRef`, then a long tail. The
  undefined fills a safe build writes (`0xaa`) are none of it (no
  samples). The branch leaves 2,788 check jumps in the runtime's files
  (`prof/branch-static.txt`), 58,641 in all.
- **Then the whole set, built and counted.** Since the share is mostly
  indirect, the blocks were written for every site of the census whose
  check the runtime's own invariant proves, and the build was counted
  exactly: 1.65% and 1.75% fewer instructions in single runs, as many as
  `zig-rt`, so the set was not bisected further.

## Method

- **Builds** (`mk.sh`, `mkpgo.sh`, `zigb`, `bolt-train`). In
  `/zfs/worktrees/rig/runtime-unchecked/`, beside check-bisect. Plain:
  check-bisect's emitted package, copied, and for the branch the three
  files of b84c20a6c copied over its `rig/`; each compiled as
  `rig build --release` does (`zig build-exe -Osafe -fomit-frame-pointer`),
  on its own, the cache removed. PGO: `rig build --release --pgo` as
  Trig ships it, by check-bisect's Rig, trained on copies of
  `bolt-train`'s four projects (mitt, neverthrow, superstruct, zod3), with
  the branch's files copied over the package before each `zig build-exe`
  (`zigb`; the files were checked after the build: the branch's in the
  branch, main's in main). Every build through
  `/zfs/trig-pup/trial/slot.sh`, `TRIG_RELEASE_SLOTS="0,5 0,5 0,5"`:
  plain 703 and 715 s, PGO 1,628 and 1,658 s.
- **Timing** (`time.sh`, check-bisect's, with the load and the free 2 MiB
  blocks logged at each end; `summ.py`, `kern.py`). `taskset -c 6`,
  core 7 idle, the two interleaved, order rotated each round, ts-pattern
  then zod3, `--noEmit --singleThreaded`; a round waits while another
  process uses core 6 or 7. Medians of each round's ratio to main.
- **Memory** (`rss.sh`). Peak RSS from `/usr/bin/time`; split into
  anonymous and file-backed by sampling `/proc/PID/status` every 5 ms
  (sampler on core 20), largest of three runs.

## Machine state, and which numbers count

The coordinator reported that from 14:05 to 16:45 (pup, MDT) another
session's fragmentation measurement could stall any Rig program asking
for huge pages (segments, #740; Tables, #754) in the kernel, by up to 34%
of ts-pattern's wall time. Each run here is judged against the quiet
kernel share, about 0.25G cycles a ts-pattern run:

| run | taken | kernel cycles, ts-pattern main / branch | used |
|---|---|---|---|
| plain1 | 15:49-15:51, in the window | 0.245G / 0.257G | quiet by its kernel share; agrees with plain3 by instructions |
| plain2 | 16:35-16:37, in the window | 0.900G / 0.657G (free 2 MiB blocks 54) | stalled: instructions only |
| pgo1 | 16:46-16:47, just after it | 0.240G / 0.245G | quiet; agrees with pgo2 |
| plain3 | 17:09-17:11, after it | 0.229G / 0.231G | **the plain numbers** |
| pgo2 | 17:11-17:13, after it | 0.218G / 0.217G | **the PGO numbers** |

The profiles (14:55-15:30) are in the window; they count instructions
and their positions, which the stall does not move. The concurrency
benches ran at 17:13-17:20. The peak RSS of every run is the same within
4 KB, in and out of the window.

## Trig, plain builds

20 rounds each, faster (25th to 75th percentile of the wall ratio) /
fewer total cycles / fewer user cycles / fewer instructions:

| run | ts-pattern | zod3 |
|---|---|---|
| **plain3** (979.7 ms, 192.6 ms main) | 0.83% (0.28 to 1.45) / 1.02% / 1.05% / 1.66% | 1.38% (0.48 to 2.43) / 2.04% / 2.25% / 1.35% |
| plain1 (861.3 ms, 175.7 ms) | 0.35% (-2.20 to 3.03) / 0.16% / 0.30% / 1.67% | 2.75% (-0.23 to 3.84) / 2.15% / 2.54% / 1.34% |
| plain2, stalled | user cycles 2.70% / 1.66% | 2.81% / 2.22% / 1.64% / 1.38% |

Peak RSS 276,976 KB against 277,200 (0.08% lower) and 92,200 against
92,628 (0.46% lower); `.text` 17,532,745 bytes against 17,923,945
(2.2% smaller).

## Trig, PGO builds

| run | ts-pattern | zod3 (trained on) |
|---|---|---|
| **pgo2** (877.1 ms, 171.4 ms main) | 1.23% (0.45 to 2.29) / 1.96% / 1.93% / 1.71% | 0.52% (-1.01 to 1.77) / 0.39% more / 0.04% / 1.07% |
| pgo1 (735.7 ms, 151.0 ms) | 0.68% (-0.36 to 1.55) / 0.71% / 1.42% / 1.71% | 0.88% (-0.59 to 2.61) / 0.73% / 0.82% / 0.86% |

Peak RSS 279,296 KB against 278,752 (0.20% higher) and 93,636 against
92,992 (0.69% higher). Split: anonymous 264,580 against 264,612 KB and
76,980 against 76,824 (within the sampling); file-backed 14,500 against
14,096 and 13,924 against 13,328. The PGO branch's `.text` is 19,748,985
bytes against 19,382,257 (1.9% larger: PGO inlines the smaller helpers
more), and its larger resident text is the whole difference. The plain
builds' file-backed pages are smaller on the branch (12,740 against
13,048 KB, 12,548 against 12,920).

## The other gates

- Rig's full suite (`tools/heavy swarm test/rig.rip all -q -w 6`, the
  self-check build, `RIG_SANITIZE=1`): 10,792 jobs, none died.
- `zig build test` on the Mac; on pup at debug, safe, and fast. The
  first debug run failed `sched.test.two tasks that answer each other
  over a socket stay on one worker` (a share of crossings under a
  quarter) while two release builds shared its cores; three debug runs
  after it passed.
- Trig's light gate (b84c20a6c by `tools/pup-rig`): GREEN in 61 s.
  loco's light gate: GREEN in 35 s (122 runs, none differ).
- std.json guard: every file 0.1-0.7% fewer instructions than
  `guard.txt` (twitter 7.879, twitterescaped 9.371, canada 16.150,
  citm_catalog 8.037, gsoc-2018 3.440, github_events 7.008). bench/hash
  guard: every row within 1% (most 0.8% more, map int-miss; text-churn
  1.0% fewer, both tables).
- bench/tasks, bench/actors, bench/net, bench/http (`benchbuild.sh`,
  `benchtime.sh`): rig-fast and rig-safe of Rig main 9f05d492e and of the
  branch, on cores 6 and 7, main and branch alternating, two rounds
  (`bench/`). Every row is the same within the rounds' spread (tasks:
  spawn 65-66 ns, chain 91-94, yield 24, hog 140.7-142.4 us; actors
  11-16 ns; net pingpong 5.38-5.63 us, echo 4.07-4.09, connect
  31.0-32.2; http rig-fast 182,000-195,000 requests a second for main
  and 183,000-192,000 for the branch, rig-safe 182,000-191,000 and
  180,000-191,000, over four rounds each, leaving out one branch round
  taken while pup's load rose to 9 (108,000), and 8.6 KiB an idle
  connection), so no PROGRESS.md row is added. Other sessions held pup's
  load at 3 to 5 throughout. An `--release=fast` build
  has no safety checks to leave out; what changes there is only
  `appendBytes`'s `@memmove`, `grow`'s saturating double, and the forms
  of the reads, which compile to the same loads.
