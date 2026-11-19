# Closing the psum gap with Rayon (2026-11-18), shared brief for three experts

Goal (the owner's): close the psum gap with Rayon, on both machines, at 1 worker and at all workers,
without slowing anything else.

## The program and the numbers

- Program: `docs/history/records/2026-11/concurrency-bench-remeasure/fork/fork.rig` (psum: sum of 2^25
  Ints, split in halves down to GRAIN 8,192, left half on a `&` task, `>a +% b`; leaf
  `for x in xs: s +%= x`), its Rayon twin `rayon/` (rayon::join, leaf
  `xs.iter().fold(0i64, |s,&x| s.wrapping_add(x))`, LTO, one codegen unit, NO target-cpu flag), and
  `run.py`. Each process times ONE psum, right after building the input: so it is the first parallel
  pass of the process (worker start-up included) over 256 MB.
- pup (x86-64, Core Ultra 9 185H), Rig a303f69fd, median of 20
  (docs/history/records/2026-11/standings-1118/rayon-pup.md): psum 1 worker Rig 14.36 ms vs Rayon
  11.89 (21% slower); 12 workers on 0-11: 6.05 vs 4.66 (30% slower). Scripts in that record's scripts/
  (s1118-fork-board.py) show exactly how it was run.
- Mac (Apple M5, 4P+6E), the same Rig: psum at 10 workers 5.3-7.1% slower than Rayon; at 1 worker
  21-22% slower.
- Already known (read these first): docs/history/records/2026-11/concurrency-fork-join/
  (measurement.md: forks are <1% of psum; the gap was the first call's start-up),
  docs/history/records/2026-11/concurrency-startup/README.md (where the first call's 0.44 ms goes on
  the Mac; fixes ranked, "workers started early" left unbuilt because it changes documented behavior),
  /Users/shreeve/Data/Code/Claude/rig/rig/fable-review/fork-join-2.md (the ring join #1147; the cold
  first pass: ~0.1 ms warm stacks/heap, ~0.1 ms waking workers, the rest the machine; Rayon pays ~0.5 ms
  too), fork-fold-2.md (rig.fold, #1146: the vector loop Zig 0.17's disabled LLVM vectorizer misses;
  psum 1 worker 5.8% faster on the Mac). Since psum at ONE worker trails by 21% on both machines, most
  of the gap is not stealing.

## Rules (read /Users/shreeve/Data/Code/rig/AGENTS.md first; these do not bend)

- Worktrees only (`wt new NAME` from origin/main); never edit ~/Data/Code/rig. Commit to your own probe
  branch; push it; open a DRAFT PR only for a change that is clean and measured. Never merge. No AI
  attribution anywhere.
- North Star: emit decides nothing (a decision is a recorded fact); safe code stays memory-safe; no new
  threads (Rig's parallelism is tasks); no state-machine tasks. A change to documented behavior or an
  ownership rule goes to the owner first (report it, don't build it).
- Mac: builds and suites through `tools/heavy`; every timing run inside `tools/mac-claim LABEL CMD`
  (at most 20 min a claim); hold off while ~/Data/Code/mumps-compare/.mac-quiet exists.
- pup (`ssh pup`, zsh: use `bash -c`/`bash -s`): timing only inside your own slot:
  `exec 9>/tmp/pup-timing.lock; flock -w 7200 9`, wait for `/zfs/trig-pup/bin/pup-slot state` to show
  slot=none, `bash /zfs/trig-pup/runs/timers-clear.sh MIN`, `: > /zfs/trig-pup/quiet-log/NN.txt`,
  `pup-slot open NN MIN ab "LABEL"` (MIN ≤ 60), always `pup-slot close NN` (trap), then
  `bash /zfs/trig-pup/runs/quiet-check.sh NN`. Timed runs on P-cores 0-11 only; builds and untimed work
  on E-cores 12-19 only and never while any slot is open. Outputs on /zfs (your own folder under
  /zfs/trig-pup/psum-gap/), never /tmp. Build the Rig under test with
  `cd ~/Data/Code/worktrees/trig/rig-light && tools/pup-rig SHA` (push the SHA first; retry on exit 75).
  The Rayon binary from 2026-11-15 is /zfs/trig-pup/bench-remeasure-3f4564a4b/build/fork/rayon.
- Never pkill/killall or pattern kills; kill only PIDs you started.
- Measure honestly: A/A arm, interleaved rounds, medians with ranges; "N% faster/slower", never +/−.
  A gain counts only beyond the A/A spread. Check every arm's output (psum's sum) matches.
- Any change must keep bench/tasks, bench/net and the speed guards (bench/json, hash, text, check
  guard.py) level, and qsort level or better.

## Your report

At most 300 words to the lead: the cause you found (with the measurement that shows it), what you
built, numbers against main and Rayon on both machines at 1 and all workers, and a draft PR link or
why not. Full details in /Users/shreeve/Data/Code/Claude/rig/rig/psum-gap/<your-area>.md.
