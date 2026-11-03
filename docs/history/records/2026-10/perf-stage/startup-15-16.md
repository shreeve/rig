# Items 15 and 16: notes (2026-10-31, Rig - Merges)

Build: pup /zfs/worktrees/rig/codegen-gap/v/main810/bin (Trig 2ba0719 PGO by Rig d0af9f62a), before pool-yield (#819).
Profiles on E-cores 12-15 (perf_event_paranoid 1: per-process only, no kernel symbols). Raw output on pup in /zfs/worktrees/rig/startup/.

## Item 15: four checkers start slower than one (mitt)

Counters, 40 runs each, `perf stat -r 40`:

| cores | checkers | task-clock | faults | user cycles | kernel cycles | instructions |
|---|---|---:|---:|---:|---:|---:|
| 12 | singleThreaded | 35.9 ms | 2,542 | 93.9M | 31.8M | 173.0M |
| 12 | 1 | 35.8 ms | 2,539 | 91.7M | 32.0M | 172.8M |
| 12 | 4 | 40.6 ms | 2,916 | 95.4M | 40.1M | 179.9M |
| 12-15 | singleThreaded | 35.4 ms | 2,543 | 84.1M | 31.1M | 172.2M |
| 12-15 | 1 | 34.8 ms | 2,540 | 82.8M | 30.5M | 172.2M |
| 12-15 | 4 | 41.5 ms | 3,153 | 90.4M | 44.9M | 180.0M |

- Idle workers cost nothing: one checker on 4 cores is the same as on 1.
- Three extra checkers cost about 4.8 ms of CPU even on one core, about 1.6 ms each, about two thirds of it kernel. On P-cores the standing measured Trig4 4.8 ms slower than Trig1 on mitt (29.8 against 25.0 ms): the same amount.
- The checkers are made one after another on the main thread, before the checking tasks start (`new_checker_pool`, checkerpool.rig); Go makes each on first use.
- Per checker, user side: `initialize_checker` is 2.3% of mitt's user samples at one checker, 6.1% at four, with `merge_symbol`, `clone_symbol` and `Ordered.rebuild` growing too.
- Per checker, kernel side: 43 Tables larger than 2 MiB are reserved (43 buddyinfo reads at one checker, 172 at four; NOHUGEPAGE 43 and 172). Each reservation costs about 16 µs of system calls on an E-core (buddyinfo read about 7.6, mmap + madvise + munmap about 8.3), and the first touch's fault about 11 more. About 0.7 ms of system calls per checker.
- strace at four checkers also shows about 106 more epoll_pwait and write pairs (worker wake-ups), 67 more mprotect calls.

Fix candidates, ranked by expected reach on mitt at 4 checkers:

1. Trig: make each checker in its own task (in parallel), as Go makes them on first use. Expected to remove most of the 4.8 ms (about 16% of Trig4 on mitt and neverthrow), making Trig4 no slower than Trig1 on small projects.
2. Rig: reserve Tables from one program-wide address-space arena: no mmap, madvise and munmap per Table, and one buddyinfo reading per burst. About 0.7 ms per checker; also helps one checker (about 2% of mitt).
3. Rig: keep hugeFree's reading for a few milliseconds. About 0.3 ms per checker; a few lines.

## Item 16: zod3 (preliminary)

E-cores, 15 runs each:

| cores | checkers | task-clock | faults | user cycles | kernel cycles | instructions | Parse | Bind | Check | Total |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 12 | 1 | 344.5 ms | 9,852 | 992M | 145M | 1,393M | 35 | 19 | 283 | 340 |
| 12 | 4 | 472.9 ms | 16,406 | 1,329M | 214M | 1,902M | 38 | 18 | 407 | 471 |
| 12-15 | 1 | 365.4 ms | 9,840 | 1,038M | 149M | 1,393M | 37 | 19 | 296 | 354 |
| 12-15 | 4 | 528.4 ms | 18,941 | 1,463M | 258M | 1,903M | 36 | 14 | 229 | 286 |

- Four checkers execute 37% more instructions than one: each checker resolves the types it meets again. tsrs duplicates too: its user time grows 53% from one thread to four (Trig's 43%, standing-5).
- Peak RSS: from one checker to four Trig adds 27.5 MB and tsrs 31.4 MB (standing-5). Trig does not duplicate more per checker; Trig4's 107% over tsrs1 comes from Trig1's footprint (84.1 against 54.0 MB).
- Where Trig4 scales worse: its system time doubles from one to four (24 to 48 ms on P-cores) and its faults grow 2.4 times (7.8k to 19.0k), against tsrs's 1.7 times; the serial head (parse and bind on one thread, 50 ms on an E-core; tsrs parses in parallel, scaling-2); and the checking is unbalanced: four checkers on four cores check in 229 ms of the 407 ms they take on one core, so the largest checker does about 56% of the work (Go's partition, which tsrs4 also used).

Next for 16: where Trig4's extra 9-11k faults come from (each checker's Tables at small pages, each heap's segments); each checker's own check time; the head's share on P-cores (needs a timing slot, after #819).

## Fix 1 prototype (Trig worktree checker-tasks, ad9ad36)

`new_checker_pool` makes each checker in its own task when count > 1 and joins them in order. rig check clean (Rig 144f70057); a debug build prints tsrs1's bytes on all six projects at 1 and 4 checkers, no leaks or panics; Trig's light gate GREEN (25 jobs, 0 died, run on E-cores with full/rig's Rig, since pup's default Rig is from Oct 26). Release builds of both sides wait for #819's merge commit (Swiss), then E-core profiles and the P-core timing.

## Item 16: balance and faults

- Balance. zod3 at 4 checkers on 4 E-cores, 5 runs each: Go's assignment Check 190-226 ms, Total 255-290; Trig's opt-in dynamic queue (TRIG_CHECKERS=dynamic, heaviest file first, as tsrs's default) Check 156-197, Total 219-265: about 18% less checking and 12% less in all. Not tsc's assignment: some programs' output depends on which checker checks which file, which is why it is opt-in. Standing-5's tsrs4 ran with Go's assignment too, so balance does not explain the gap to tsrs4.
- Faults. pup had no free 2 MiB blocks (buddyinfo orders 9 and 10 empty), so the huge-page gate was shut and every Table and segment faulted 4 KiB at a time. Page-fault samples (`perf record -e page-faults -c 1`): 9.9k at one checker, 19.2k at four, in the checker's type builders (resolve_structured_type_members_worker 1,764 to 3,468, instantiate_type_with_alias 1,623 to 2,952, set_structured_type_members 247 to 873, memcpy 427 to 1,248): each checker's own copies of the types it builds. Trig adds about 9k faults for 27.5 MB from 1 to 4 (about 3 KiB each); tsrs adds 3.9k for 31.4 MB (about 8 KiB each).
- Lead: Tables faulted in ahead (the memory-traffic ceiling: 64 KiB ahead, 2.7% fewer cycles and 64% fewer faults at one checker, for 0.6-2.0% more memory; table-prefault #699 was not taken). At four checkers the faults weigh more; worth timing again there. Rig-side (table.zig), after #815 and seg.
- Swiss: the faults lead was tried (archive/table-ahead, archive-tags.md): 65% fewer faults but 0.4% fewer cycles at one checker; the ceiling's 2.7% came from same-binary env arms. A re-time at 4 checkers uses plain separate builds against plain main, 20 rotated rounds, judged by user plus kernel cycles; after #815 and seg. Balance: keep tsc's assignment.

## Fix 1 timed (2026-10-31 18:28, pup P-cores, Swiss's slot)

Trig main aa3994b against checker-tasks (ad9ad36), both PGO by Rig 2e30e8457 (main with #819), 20 rotated rounds, six projects; every output the same. Table: [startup-15-16-data/summary.md](startup-15-16-data/summary.md); raw: [startup-15-16-data/times.txt](startup-15-16-data/times.txt).

- At 4 checkers: mitt 1.0% less wall by the median (3.7% more by the fastest), neverthrow 2.6% less (3.6% less), zod3 1.4% less (the same), ts-pattern 0.5% more; user plus kernel cycles 0.5-5.4% more. Trig4 on mitt is still 30.2 ms against Trig1's 25.8. It does not clear Trig's bar (more than 2% faster).
- Why so little (E-cores, mitt, 30 runs each, per-thread timestamped samples): from the end of binding to the first checking sample, one checker takes 4.0 ms, four made one after another 8.6, four made in tasks 6.5. The other threads' first samples come 2.3 ms after binding ends (6.5 in base, where they first run to check). So making them in tasks recovers about half: the tasks start late and the four constructions run about half as fast side by side as one alone.
- Likely contention (not proven): each construction makes 43 reservations (mmap and madvise, which take the process's mmap_lock for writing) and faults its first pages; 172 at once. Rig - Helper's Table arena (#830) removes the reservations; fix 1 is worth timing again stacked on it.
- Verdict: no Trig PR now; keep checker-tasks as a local branch to stack on #830.

## Item 16 settled: the gap at four is the serial head, not the split (2026-10-31 evening)

zod3 phases (`--extendedDiagnostics`), medians of 15 alternated rounds on E-cores, one thread on 12, four on 12,13,18,19 (two clusters; other builds ran on 14,16,17). Trig main aa3994b PGO by Rig 2e30e8457; tsrs shipped with Go's assignment (`phases.sh` on pup in /zfs/worktrees/rig/startup/):

| | Parse | Bind | Check | Total |
|---|---:|---:|---:|---:|
| Trig, 1 | 32 | 12 | 230 | 277 |
| Trig, 4 | 32 | 12 | 106 | 155 |
| tsrs, 1 | 18 | 6 | 181 | 209 |
| tsrs, 4 | 15 | 0 | 109 | 130 |

- Checking at four is level with tsrs (106 against 109 ms) and scales better (2.2 times from one to four, against tsrs's 1.7). Trig's split is Go's (static weights from node count, text length and imports, heavy source files first, importing files kept together), and tsc's output can depend on it, so it stays. The earlier "largest checker does 56%" came from four threads in one E-core cluster (12-15), which skewed it; here the largest does about 46% (106 of 230).
- The 25 ms gap is the head: parse 32 against 15 (17 ms) and bind 12 against 0 (12 ms). Trig parses and binds on one thread (new_program, program.rig: each file parsed by the loader, then bound into the shared `names`).
- Parse. lib.dom.d.ts is 2.4 MB of the program's 3.5 MB (68%; lib files 3.04 MB, zod3's own 0.49 MB, types.ts the largest at 161 KB). Parsing in parallel is bounded by that one file: at most about 10 ms saved at four. Parser speed is the larger lever: Trig parses in 32 ms what tsrs parses in 18 on one thread (1.8 times); Rig - Rust's lexer and parser work.
- Bind. Trig binds in 12 ms against tsrs's 6 on one thread, and tsrs shows none at four (it binds in parallel or within parsing). Trig's binder interns every file's names into one shared table, so binding in parallel needs per-file names merged afterwards, a design change that must keep atom order (output). Bounded by lib.dom.d.ts's share too: at most about 8 ms.

Ranked, for zod3 at four checkers (E-core ms of the 25 ms gap):
1. Parser speed (Trig, Rig - Rust): up to 14 ms (32 to 18).
2. Parallel parse, Go's loader queue (Trig, compiler/fileloader): up to about 10 ms, less after 1.
3. Binder speed and parallel bind (Trig, binder; a design round for per-file names): up to about 8 ms.
4. Checker construction (fix 1 stacked on #830): 2 to 4 ms.
P-cores (standing-5's gap 33 ms) not yet measured by phase; needs a timing slot.

## Fix 2 prototype: parse the libs ahead (Trig worktree lib-parse-ahead)

- Rig - Rust confirms the parser shares no state between calls (trig#230 keeps it so).
- Change (fileloader.rig, filesparser.rig): a bundled lib's tree depends only on its name and text (declaration files always parse with default options), so the libs the program starts from and every lib their headers name (`/// <reference lib>`, found by a text scan of the first 8 KiB) are parsed ahead from the start, each in its own task, largest first (lib.dom.d.ts first); the walk takes each tree in its turn (`take_ahead`), and leftovers are joined at the end (`finish_ahead`). Files and their order are unchanged: rig check clean, a debug build prints tsrs1's bytes on all six projects at 1 and 4 checkers, no leaks or panics.
- First version (prefetching a lib's references when it is parsed) gained nothing: the walk (last queued first) reaches lib.dom.d.ts right after queuing it.
- Debug builds, 4 E-cores: zod3 Parse 860 to 780 ms (about 9% less); mitt no change. Per-thread samples on mitt: 144 of 175 parser samples on one thread, so most of the libs are still parsed there.
- Why (Rig's scheduler, sched.zig `wake`): a spawned task goes into the spawning worker's "run next" slot, and filling it "wakes no worker"; work spreads at the parent's next yield check, or when another spawn pushes it to the ring, and a sleeping worker is woken "only when none is looking". Good for fork-join where the parent soon yields; poor for "start several jobs now, keep walking, join later", as here and in fix 1 (whose other tasks started 2.3 ms late). Possibly a common, Rig-side cause for both: a spawn that wakes a sleeping worker when the spawner keeps running.
- Not yet measured in release builds.

## Sched-wake A/B (2026-10-31 evening)

- Rig 1684f645a, plain and hack (sched.zig `wakeSpawned`: a spawned fiber whose spawner keeps running goes to the ring and `notify()` wakes a sleeper), built 19:31 and 19:35 in pup:/zfs/worktrees/rig/sched-wake.
- Found on the way: the start-of-walk lib prefetch never ran, because `tsoptions.get_lib_file_name` does not map the default lib's file name (`lib.es2026.full.d.ts`); fixed with `lib_file_name_of` (lib-parse-ahead 2nd commit). With it, debug builds show three workers parsing libs from about 21 ms.
- Debug builds mislead for this: in the release build the parse phase is 62% parser and lexer, 10% copies, the loader under 4% (mitt, 20 runs).
- Release builds (no PGO, the same for every arm), one at a time on E-core slots: main and fix12 (fix 1 + fix 2), each by plain and hack Rig. Then timing in Swiss's slot.

## Fix 1 stacked on #832 (Helper, 2026-10-31 21:03, P-cores, 20 rotated rounds, Trig aa3994b)

Table: [table-arena-data/pcore-times.md](table-arena-data/pcore-times.md) (pup /zfs/worktrees/rig/item15/times.txt). In Helper's arms "fix2" is #832 (the Rig reservation fix), not lib-parse-ahead; "-ct" adds checker-tasks (ad9ad36). Outputs identical.
At 4 checkers, checker-tasks on top of #832 alone, by wall median: empty 2.9% less, mitt 2.8%, neverthrow 4.2%, zod3 1.5%; peak RSS about 1% more. Without #832 it pays nothing (0.4% more to 2.1% less, cycles 1–7% more): the reservations serialized the tasks. One checker does not run the new code.
Still to measure before the Trig PR: ts-pattern at 4, on main with #832 merged; then Trig's light gate.

Sched-wake PR (if it pays): rebase onto Rust (fork)'s 25g (EINTR retry honors cancel/SIGTERM; edits sched.zig, tasks.zig) after 25g lands. Swiss, 2026-10-31.

## Sched-wake A/B, run 1 (2026-10-31 22:08–22:18, P-cores, 20 rotated rounds, Rig 1684f645a, Trig aa3994b)

Table: [spawn-wake-data/run-1.md](../scheduler/spawn-wake-data/run-1.md); raw: `sched-wake-1.times.txt`, on pup in `/zfs/trig-pup/records-data/startup-15-16/`. Outputs identical in every arm.
Confound: peak RSS is constant per binary and splits by build, not by arm: main-plain and fix12-hack about 30.0 MB on mitt at one checker, main-hack and fix12-plain about 33.7 MB, with about 800 fewer page faults (`--version` alone differs by 1 MB the same way). THP is `madvise` on pup, so a 2 MiB-backed reservation lands in some builds and not others. It moves small-project wall time by about 2–3%. The 2×2 cancels it: each effect below is the mean of its two pairs (hack: mh/mp and fh/fp; fix12: fp/mp and fh/mh), wall median.
- Hack (wake on spawn), 4 checkers: mitt 2.9% less, neverthrow 3.4%, superstruct 4.0% (pairs disagree: 8.8% less and 0.8% more), zod3 1.0%, tiny-invariant 0.6%, ts-pattern 0.1% more. One checker: 0–3% less, mostly the confound.
- fix12 (lib-parse-ahead; checker-tasks pays nothing before #832), 4 checkers: superstruct 12.1% less, mitt 9.7%, neverthrow 5.8%, zod3 0.6%, tiny-invariant 0.6%, ts-pattern 0.6% more.
Verdict: the hack's gain is real-looking on small projects but no larger than the confound; not enough for a scheduler PR. Rerun on Rig with #832 merged (no reservations, so no THP split), all arms one Rig base, before deciding. Fix 2's small-project gain is large and worth its own measurement on main+#832.

Rerun plan (Swiss agreed 2026-10-31): after #832 merges, one 15-min slot, the 2x2 at 1 and 4 checkers, ts-pattern included; fix 2 must not be slower at one checker. If fix 2 holds and ts-pattern stays flat, fixes 1+2 go to Trig as one PR for the owner. Sched wake stays an experiment until a clean run beats the noise.

## Sched-wake A/B, run 2 (2026-11-01 01:17–01:29, Rig 95fffb6cf with #832, Trig aa3994b, same 2x2)

Table: [spawn-wake-data/run-2.md](../scheduler/spawn-wake-data/run-2.md); raw: `sched-wake-2.times.txt`, on pup in `/zfs/trig-pup/records-data/startup-15-16/` (mitt from a rerun at the end; its first rounds overlapped three resumed builds). Outputs identical everywhere.
The RSS split survives #832 (main-hack and fix12-plain about 10% higher on small projects, main-plain and fix12-hack equal), so it is not the table reservations; segment layout shows nothing obvious. Unexplained; the 2x2 mean still cancels it.
Effects, mean of the two pairs, wall median:
- Hack, 4 checkers: superstruct 3.7% less, mitt 3.5%, neverthrow 2.5%, tiny-invariant 0.9%, zod3 0.2%, ts-pattern 0.7% more. Repeats run 1 (2.9/3.4/4.0% on mitt/neverthrow/superstruct).
- fix12, 4 checkers: superstruct 13.1% less, mitt 9.1%, neverthrow 6.1%, tiny-invariant 1.6%, zod3 1.5%, ts-pattern 0.4% more.
- fix12, 1 checker: mitt 3.0% less, neverthrow 2.5%, tiny-invariant 1.0%, zod3 0.3%, superstruct 1.6% more, ts-pattern 0.7% more. ts-pattern at one checker is slower in all four pairs over both runs (0.6–1.0%), cycles too: small but consistent. Fix 1 does not run at one checker, so it is fix 2's prefetch.

## Lead from Rig - Rust (2026-11-01): the load phase is slower at four checkers

Trig dd43341, pup, 20 rounds, plain release by Rig ad5d9b043. process_all_program_files: zod3 17.9 ms at one checker against 21.4 at four, ts-pattern 18.4 against 20.8, empty 10.2 against 10.5. tsrs's parallel parse-and-resolve barely helps it either (zod3 11.0 to 10.0). Data in [head-phases.md](head-phases.md); timers in [head-phases-data/timers.diff](head-phases-data/timers.diff) (applies to Trig dd43341).
At four, parse-ahead (trig#232) runs the libs in tasks and the walk joins them in turn. A likely cause is the walk blocking in take_ahead on lib.dom's task, which the scheduler starts late, since a spawn wakes no worker; that's the sched-wake question. Other suspects are contention on fresh pages and the blocking-pool hops on reads (Rust, 2.5–3.3 ms on E-cores). Check with per-task timestamps (spawn, start, end, joined) before changing the loader; the wake-on-spawn arm is the natural A/B.

## Standing-7 (queued after trig#240 and the union cache; Swiss, 2026-11-01)
- time-ab.sh, 1 and 4 checkers, peak RSS from tmpfs.
- Like-for-like: tsrs in Go mode (--noLazyMembers) against Trig without the three extra libs.
- As shipped: tsrs with lazy members (its default) against Trig with its libs.
- Report both tsrs modes side by side (Swiss relays the owner's OK; Rust found Go-mode tsrs about 3.9% slower than shipped on ts-pattern, and every past standing used Go mode).
