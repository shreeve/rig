# Closing psum's gap with Rayon, 2026-11-18

Three experts on psum against Rayon (leaf and codegen, the fork-join runtime, the memory system), the reviews
and boards that followed, and the Zig 0.17.1 check run the same evening. The brief is [BRIEF.md](BRIEF.md).

- **The leaf** ([leaf.md](leaf.md)): `rig.fold` added 16-byte vectors on every target; on pup's cores that loop
  reads memory 12-15% slower than 32-byte vectors. A fold now adds the widest vectors the target has (#1151):
  psum at one worker on pup 14.32 to 12.37 ms against Rayon's 11.97. The Mac's code is identical.
- **The memory system** ([memory.md](memory.md)): at 12 workers each new worker's first allocation zero-fills a
  2 MiB huge page inside the timed pass. A heap whose first 2 MiB keeps small pages (#1156) took psum at 12
  workers from 5.97 to 4.78 ms, but costs single-thread time.
- **The runtime** ([runtime.md](runtime.md)): the 12-worker gap is the cold first pass (huge-page zeroing about
  1.5 ms, thread start about 0.8 ms); at one worker the twins walked memory in opposite orders, which the
  fork-order record fixes; a join costs 60-86 ns against Rayon's 10-14 (#1152 takes a third off on x86).
- **The race** ([review-1152.md](review-1152.md)): reviewing #1152 found a race on main from #1147 (a thief and
  a ring's owner could both take one fiber); #1157 fixes it with a per-ring `stealing` flag, reviewed sound.
- **Stacked** ([stack-board.md](stack-board.md)): huge pages plus early start took psum at 12 workers to 4.18 ms
  against Rayon's 4.69. Trig's A/B ([raw/trigAI-both.txt](raw/trigAI-both.txt)) found Trig at one checker
  1.5-3.2% slower with both; the bisect ([raw/trigAJ.txt](raw/trigAJ.txt)) found both changes share it, so #1156
  is dropped and #1158 reworked: `task.workers` lazy again, and early-started workers fault their heap's first
  segment before looking for work.
- **Zig 0.17.1** ([raw/zig-0171/](raw/zig-0171/)): every gate passes; on pup the HTTP, net, tasks and fork rows
  are level, and std.json's canada and gsoc-2018 run 2.5-3.2% slower over 30 rounds
  ([raw/zig-0171/json30.txt](raw/zig-0171/json30.txt)). The owner kept Rig on 0.17.0.

The scripts that ran the pup work are in [scripts/](scripts/).
