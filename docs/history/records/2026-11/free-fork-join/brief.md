# Free fork-join, the build round: brief (2026-11-18)

The owner, 2026-11-18: "Start the free fork-join design round now. We need to beat psum with 12
workers." Free fork-join was approved on 2026-11-15 (records/2026-11/concurrency-fork-join/
SYNTHESIS.md, items 1-7) after the direction of 2026-11-07 (records/2026-11/fork-join/
decisions-2026-11-07.md). That round settled *what* it is and that it is sound. This round settles
*how it is built on today's scheduler* and *what it buys*, so a builder can start from its synthesis.

Fixed points, never reopened: one model, `f()&` and `>t` on real stacks; no async, no colored
functions, no state-machine tasks; Rig never adds threads; one preemption way per target; one `&` for
every kind of task (free fork-join is a path inside it); emit decides nothing (a decision is a fact).

## Where psum stands (read these)

- pup (x86-64, Core Ultra 9 185H), fork-order's fork.rig (records/2026-11/fork-order/, rayon::join's
  order), Rig 08b2caf1a, one psum a process: 1 worker 11.99 ms against Rayon's 11.89 (level);
  **12 workers 5.77 against 4.72 (22% slower)**. Mac (M5, 10 workers): 2.74 against 2.64.
- Why 12 workers trails on pup: `~/Data/Code/Claude/rig/rig/psum-gap/` (runtime.md, memory.md,
  leaf.md). The timed pass is the process's first parallel pass. Its cost is (a) each worker heap's first
  huge page zero-faulted inside the pass, about 1.2 ms (fix: draft #1156, `seg-first-small`), and (b)
  threads still starting as work spreads, about 0.8 ms (fix: #1158, `early-start`, workers start as
  `main` starts). Both are approved and in gates. A probe with both effects removed ran the first pass
  in 3.87 ms against Rayon's 4.32. Warm passes: Rig 3.14-3.24, Rayon 3.09-3.16.
- Per join at one worker Rig pays 60-86 ns where Rayon pays 10-15 (runtime.md, `nil`). The cold first
  pass touches about 170 fresh task stacks; each fork allocates a record from the worker's heap; the
  preemption monitor wakes every 50 µs while a ring holds work.
- The scheduler since 11-15: the ring join (#1147: `>t` takes back the newest task from its own ring,
  a Chase-Lev owner pop, `takeLast`), the ring race fix (#1157: a thief holds the ring's `stealing`
  flag from its look at the tail to its claim), relaxed handoff stores (#1152), dense stacks, one
  poller on the Mac.

## The open questions this round answers

1. **Recursion.** The 11-15 synthesis inlines only a task whose stack use is proven bounded. psum and
   qsort recurse (`b = psum(xs[mid..])` is a plain recursive call), so under that rule they would never
   inline, and free fork-join would not touch the row it exists for. What rule inlines psum's and
   qsort's forks soundly, without changing SPEC's 64 MiB stack? (For example a room check at run time
   at each `>t`: each nested fork checks again at its own wait, so only plain recursion between two
   waits needs a bound; or a bound per frame times a depth the checker can or cannot prove.)
2. **The queue.** The ring already has an owner pop and a thief's claim under a flag. A separate
   Chase-Lev fork deque, or the ring as it is with a fork kind? Which one keeps forks out of the
   monitor's `queuedHere`, gives a stolen bit for `par`, and costs least per fork?
3. **What it buys, measured first.** Owner's rule: the fastest Zig first, then make Rig emit it. A
   hand-written Zig fork-join (records in frames, inline join, a deque, thieves take the oldest) on
   psum and qsort, cold and warm, 1 and all workers: how close to Rayon, and how far past it, can a
   runtime of Rig's shape go? Which pieces of today's cost does free fork-join remove (record
   allocation, stack per fork, switches, join stores, monitor wake-ups, the first pass's heap and stack
   faults), each with its share?
4. **The build.** The order of commits, each separately measurable and revertible; what the checkers
   record (the record's home, the room fact); what changes in SPEC §18, CORE (sentence 6, tasks), the
   oracle (expected: nothing); which Lean models in `formal/Models/` (Ring.lean, Sleep.lean) cover the
   new queue and must be extended before code; the tests (`seeds: 20`, `RIG_WORKERS=1`, a race
   torture in test/cli).

## Who answers what

- **Expert A, the ceiling** (question 3): builds and times the Zig ceiling. The only expert who
  builds or times anything.
- **Expert B, the runtime** (questions 1 and 2 from the scheduler's side, and 4's runtime commits and
  Lean models).
- **Expert C, the language** (question 1 from the checker's side, and 4's facts, SPEC, CORE, oracle,
  tests, and a soundness review of B's design).

## Rules (read /Users/shreeve/Data/Code/rig/AGENTS.md first; they do not bend)

- Write only in this record's folder in the worktree
  `/Users/shreeve/Data/Code/worktrees/rig/ffj-design/docs/history/records/2026-11/free-fork-join/`
  (your report, and for A the `ceil/` programs and `raw/` data). Never edit any other file, any other
  worktree, or `~/Data/Code/rig`. No commits; the lead commits.
- Read code at origin/main (`git -C ~/Data/Code/rig show origin/main:PATH`) and the two drafts:
  `git show origin/early-start:...`, `git show origin/seg-first-small:...`.
- Expert A: builds through `/Users/shreeve/Data/Code/rig/tools/heavy CMD`; every timed run inside
  `/Users/shreeve/Data/Code/rig/tools/mac-claim LABEL CMD` (at most 20 minutes a claim); hold off while
  `~/Data/Code/mumps-compare/.mac-quiet` exists. Nothing on pup or burst: write the pup job (a script
  that builds and runs the ceiling and the Rayon twin on P-cores 0-11, outputs on /zfs) and the lead
  sends it to the Rig session, which owns pup. Never pkill or killall; kill only PIDs you started.
- Zig 0.17: read the owner's guide `/Users/shreeve/Data/Code/rig/ZIG-0.17.md`; the installed std is
  the authority.
- Measure honestly: interleaved rounds, medians with ranges, an A/A arm, every arm's sum checked;
  "N% faster/slower", never +/-. Rayon twin: records/2026-11/fork-order/rayon/ (`cargo build
  --release`, offline).
- Vocabulary: tasks and cores, never threads for Rig's parallelism; self, never receiver; lend, view,
  loan, never borrow; an `obj` is an object.
- Timeless prose; numbers as measured.

## Your report

To the lead: at most 400 words, ending with your recommended defaults as a numbered list. The full
report in this folder as `ceiling.md`, `runtime.md` or `language.md`.
