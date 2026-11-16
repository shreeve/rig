# Breaker review (expert 2), 2026-11-15

(a): the form the rule newly accepts, today's verdict. (b): the same
aliasing through `+h`, under `RIG_SANITIZE=1`, tasks also under
`rig test --seeds=20`. Programs: scratchpad `panel-b/`.

| # | Attack | (a) today | (b) |
|---|---|---|---|
| 1 | ensure view kept while 20,000 puts (and 4 tasks) grow the map (m1) | rejected | clean |
| 2 | two `!Cell` views from `!h.cell()`, one in a task (t4) | rejected | clean; rebinding `h` rejected |
| 3 | `(!h).bump()&` beside `!h.bump()` (t1, a3) | rejected | **Zig fails** |
| 4 | rebind or move `h` while that task runs (t5, k11) | rejected | still rejected |
| 5 | that task returned or put in `Tasks` (t2a, t3a) | rejected | read loans carry; rebinding rejected (t2c, t3b) |
| 6 | nested word-Cell object, two `!Hits` views (n1) | rejected | clean |
| 7 | handle field `o.h`: view live; replaced mid-call (n2) | rejected | clean; replacing stays rejected |
| 8 | repoint or assign a handle field from `!@` (w1) | rejected | rejected |
| 9 | channel of handles (n3) | rejected | clean |
| 10 | Signal: re-entrant `set`; subscriber drops a handle (s1, s2) | rejected | clean |
| 11 | a drop inside Cell `set` pushes back into the cell (c1) | n/a | clean |
| 12 | `swap` of a `Cell[String]`; `compare_swap` (c2) | rejected | clean |
| 13 | re-entrant call through an upgraded weak handle (r1) | rejected | clean |
| 14 | a call drops the last other handle (r2) | rejected | clean |
| 15 | generic `*T`, `!T` (g1-g5) | rejected in sema | n/a |
| 16 | generic `Cell[T]` object (g6) | rejected | clean |
| 17 | `(!c)[0] = (!c).pop() ?? 9` (e1) | **accepted** | bounds panic, safe |

## Outside the rule
- **A North Star 1 hole.** `(!h).bump()&` on any object that holds a Cell
  passes `rig check`, but Zig fails (`Counted(Hits)` has no `bump`). The
  rule's task clause rests on that row. `run(!h)&` works.
- **Two classifiers.** An indexed store through a `Cell[List]` takes no
  write loan (e1). The marked call does (c09).

## To write down
A read-loan task is not pinned, so `!ts.add((!h).bump()&)` and
`return (!h).bump()&` become legal: sound (5), equal to `work(+h)&`.
CORE should say so.

## Open point 3
Follow the self. Through a write view, a call on a value that changes
only by mark should lend to read: `c: !Cell[Int]`, and
`(!@).bump((!@).bump(1))`. A `!@` cannot replace or repoint any field
(8). The value lives only behind a handle, and no generic body meets one
(15). `!h` standing alone (k04) stays write.

**Verdict: NOT BROKEN (17 attacks).**
