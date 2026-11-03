# Approved by the owner, held until Rig - Helper's current work lands (2026-10-30)

The owner's words: "I approve all the items in this agent also. They may conflict
with the 'Rig - Helper' agent though, so let's wait for that to finish, unless you
can verify that these won't impact each other."

Approved:
1. **Memory PR A (runtime):** A1 net read into the worker's block, A2 lazy signal
   stack, A3 `noinline` deadlock walk, A4 fresh stacks untouched. `reviews/mem-consensus.md`.
2. **Memory PR B (allocator):** B1 take other heaps' remote lists before carving,
   B2 no safe fill in String/List growth, B3 a program-wide bound on the large-block cache.
3. **mini-redis decision 1:** `net.Stream.split() -> (Reader, Writer)`.
4. **mini-redis decision 2:** no change to G15 (weak `~Chan` in an actor) now.
5. **mini-redis decision 3:** `try_send` goes to the backlog.
6. **Scheduler tick (a):** the per-loop tick checks once every 1,024 iterations in loops with a known bound.

Why held (checked 2026-10-30 against Helper's worktrees):
- PR A edits `src/runtime.zig`, which drop-speed (#773) and inline-generic both change; its
  numbers also move once drop-speed's cheaper drops land.
- PR B edits `src/alloc.zig`, which thp-spare changes, and overlaps queue item 7 (M2, the
  allocator round): B1 and B3 belong in that round.
- `split()` and A1 both change `src/net.zig`'s read path: one builder, one PR after PR A.
- The tick changes emit and every loop's timing, so it lands after inline-generic and drop-speed
  are measured.

Send to Helper when drop-speed, inline-generic, and port-bugs have merged.

## Sent (2026-10-30, after #777 merged at 71bbc1820)
Helper's builders had all merged and it had no worktrees left, so items 1, 3 and 6 went to Rig - Helper.
Item 3 comes after PR A. Item 2 (PR B) waits for Swiss's #778, which changes `src/alloc.zig`.
