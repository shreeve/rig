# Revamp of the runtime and std (2026-11-03)

## North Star
AGENTS.md, "The North Star": accept means correct; safe code cannot corrupt memory;
effects stay visible; one classifier per fact; ownership features fit the Core; docs
claim only what runs. For the runtime and std: no GC, no hidden allocation, the cost
model of Zig and C, std.json/Map/HashMap/std.text never slower (guards within 2%).

## Owner's inputs (2026-11-03 ~05:45)
1. Scope: runtime + std first (src/runtime, sched, tasks, net, alloc, ordered,
   unordered, table, nametable, split, units; std/). Compiler phases later.
2. Landing: themed PRs from worktree `revamp`; I merge on green gates and clean
   basecheck. Overnight (~05:50) he gave full authority: "performance and
   efficiency and consistency"; CORE and language rules stay fixed.
3. std's public API may change when clearly better, with CHANGELOG, migration
   note, and a Trig note and script before merge.

## Base and toolchain
- Base: main edc481031 (after #900). Worktree ~/Data/Code/worktrees/rig/revamp.
- Zig 0.17.0 (mise.toml); reference ZIG-0.17.md; std at
  ~/.local/share/mise/installs/zig/0.17.0/lib/std. Nexus 2.0.0.

## Baseline
- `zig build` (ReleaseSafe): 76 s under tools/heavy, bin/rig 9.2 MB.
- Scope size: 36,266 lines (src runtime pieces 24,0xx; std 13,082, of which
  generated tables ~1,700).
- Guards on base (instructions, Mac): json, hash (Map and HashMap), text all within 1.1% of guard.txt.
- Core suite: 7,008 jobs, 0 died, 110 s with 6 workers (3:20 with the build).

## Findings, decisions, status
(audits: audit-runtime.md, audit-concurrency.md, audit-std.md beside this file)

### Triage (2026-11-03 ~06:40)

72 findings: audit-runtime.md (R1-R18), audit-concurrency.md (C1-C22),
audit-std.md (S1-S32). No memory-safety bug in safe code. Eight hangs or
spins, every one reproduced by a probe. Spot-checked: R1, R3, C2, C3, C5
(cited lines read).

Round 1, three implementers on Opus, each in its own worktree and PR:

| PR | Findings | Files |
|---|---|---|
| rv-output | R1, R2, R3 (one writer: no user code under output_lock, String(...) in one pass), R4, then R5-R18 | src/runtime.zig (print, String, finish), src/alloc.zig |
| rv-tasks | C2-C6 (panic paths, slots, spin waits), C1 (accept waiters), C7, C9, C13, C14, C15, C20, C22, C11, C17, C18, C19, C21 | src/tasks.zig, src/sched.zig, src/net.zig, runtime.zig `fail` only, std/task, net, time, file, os, docs |
| rv-std | S3, S4, S5, S6, S8, S11, S12, S13, S14-S19, S21, S24, S25, S26-S29 | std/*, src/ordered.zig, src/unordered.zig, docs/STD.md |

Deferred:
- To the owner (names and behavior): S2 (a per-process hash seed changes
  HashMap order run to run; Map's order unchanged), S10 (needles taken as
  views: a signature change for Trig), the API-consistency table (json's
  names, compare -> Order, equal, to_float, powf), S9 (remove std.iter),
  S32 (random's sequence changes), the BigInt Eq/Ord rule, small-block
  memory returning to the system, print depth by address.
- Round 2 (needs Trig or bench timing on pup): S7 (Interner load factor),
  C8 (file I/O without `lent`), C10 (accept's poller), S1 (terminal
  bounds, Ghostty conformance), S22, S23, S20, S30, S31, C12, C16.

### Round 1 landed

- #902 (rv-output) merged 4efbc9244: R1-R18 but R2's assertion and R15's
  map-outside-the-lock (reasons in the PR). Gates: core 7,014/0, guards
  (json 0.1-1.2% fewer, hash within 0.1%, text 0.1-0.6% fewer, print 59
  of 78 bytes), loco GREEN, Trig light GREEN (31 s), pup zig build test
  debug/safe/fast. List.clone of 1,000 Ints 0.45 s where 1.33 s.
- #903 (rv-std) merged 7cdd87e0b: S3 docs only (DIT costs 38% on a 64-byte
  seal+open, M5), S4, S5, S6 but terminal (its own decoder is 3% faster),
  S8 (std/bigint.zig gone), S11-S13, S14-S19, S21, S25-S29. is_valid 80 us
  where 127 us per MiB mixed. Lead's differential probe: 0 mismatches over
  20,000 random strings. Trig light GREEN, pup zig build test x3.
  New public names for the owner's batch: utf8.block_errors,
  utf8.weighted_count[four].
- main 7cdd87e0b: core suite 7,016 jobs, 0 died.
- Round 2 started: rv-std2 (S1, S7, S20, S22, S23, S30, S31).

### #904 (rv-tasks) in review

- The implementer reported main over the guards (Map text-hit, json
  twitterescaped); main measured clean. The branch's own last commit
  (panic reports rendered into a Spill on every panic) made Map text-hit
  58% and text-churn 8.6% more instructions; fixed by rendering only when
  printing may run program code (76cb40e31): guards within 0.1%.
  Lesson: run the guards on the branch head, every time, before merge.
- Trig light GREEN and pup zig build test x3 at 76cb40e31.
- Independent review (review-904.md): R1 (task.all's Wakeup on the stack,
  written after a panicking waiter's frame is gone; introduced by C22)
  and R3 (on main: an isolate releases a panicked task's stack while its
  child tasks read it, a safe-code use after free) to fix before merge,
  with R2, R4, R7. Sent back to the implementer.
- Started rv-self: "receiver" to "self" (and "borrow", Rig "struct") in
  the compiler's comments, identifiers, and diagnostics; emit identical.

### Round 2 and #904's speed

- #905 (rv-std2): S1 (a char keeps 64 runes, as Ghostty; unused styles
  dropped in bulk: the audit's probe 164 MB to 4.8 MB; Ghostty agrees on
  2 new recorded cases and 5,000 fuzz streams; bench/terminal within 2%),
  S7 (Interner rebuilt at half full: 100k strings, hits 12.6 to 8.6 ns,
  misses 15.5 to 9.0 ns), S20, S30 (find_last of a byte on 64 KiB 75.7 us
  to 0.7 us), S31 in part. Rejected: S22 (needs a checker-declared table
  method), S23 (generic code cannot call the built-in tables' methods),
  S31's search (lower_bound takes the needle by value).
  Trig timing on pup (time-ab, 20 rounds, P-core 6, A/A arm, Trig 35ebd7a
  release by main and by #905): every project within the A/A spread
  (ts-pattern 785.4 ms vs 787.9 and 792.2; zod3 146.1 vs 145.2 and 146.8),
  RSS level. Trig light GREEN.
- #906 (rv-self): "receiver" 630 to 0 in the compiler (kept: channel
  sense, records' probe names, oracle-named test functions); emit-diff
  identical over 34 programs and 557 files, Trig included.
- #904 Mac benches, alternated against main (3 rounds, rig-fast): spawn
  10-20% slower, actor solo and contend about 7%, net connect 3-4%;
  bench/http cannot run back to back on the Mac (ephemeral ports).
  Sent back to find and remove the cost.

### Round 1 and 2 closed (2026-11-03 evening)

- #906 merged 3b2130134; #907 merged; #904 merged after its review fixes
  and two speed rounds (pup P-core 6 against main 7cdd87e0b: spawn
  78-79 vs 77-79 ns, chain 86 vs 86, yield 34-35 vs 34; actors and net
  level, connect 1.9% faster). Its final gates were run at 82f8a94df,
  with main merged in: core 7,032/0, guards 0 rows over, loco GREEN,
  Trig light GREEN, pup zig build test x3.
- Corpus check: 1,286 .rig files under ~/Data/Code, checked by edc481031
  and by main, gave identical results (932 accepted, 354 rejected by
  both).
- Round 3's brief is next-round.md; the owner's decisions are
  owner-decisions.md; the hygiene audit is audit-hygiene.md (applied in
  #907); the #904 review is review-904.md.
