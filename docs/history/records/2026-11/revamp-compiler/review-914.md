# Review of PR #914 (rv-sema)

Built `origin/rv-sema` in a separate detached worktree (needs `-Dnexus=~/Data/Code/nexus/bin/nexus` outside ~/Data/Code). Compared with main's
`/Users/shreeve/Data/Code/worktrees/rig/revamp-c/bin/rig` (a4e4ce6a8). Probes are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/45a7b8df-588d-46f9-ab76-f1ed2a2c6a62/scratchpad/p/`.
I ran no suites. The PR's numbers were not re-measured.

Verdict: M2, M3, M5/M6, S1, and the HeldParts refactor are sound. M1 closes the audit's hole and every
sibling I tried, but its handling of recursion has two defects. One is a remaining (contrived) unsound
acceptance. The other is a newly wrong rejection. Both come from one line, the in-progress branch of
`instanceBlock`.

## 1. M1: a cached held-list from inside an SCC is incomplete, so a program is accepted unsoundly and the answer depends on field order (Medium-High)

`src/sema.zig:11468-11476` (`instanceBlock`, in-progress branch), `11489-11505` (`fieldsBlock` caches `held` per `WalkKey`).

When an instance of `G` is reached while some `(G, how')` key is in progress, its own parameters are
skipped. The skip assumes the in-progress frame will collect their uses. That holds when the in-progress
key is the current frame. It fails when a second key of the same declaration sits between them:
`(G, shares)` → chan elements → `(G, moves)` → `up: ?G[T]` → `(G, shares)` in progress → skip. The
`(G, moves)` list is then stored without "T shares via `up`", and a later `G[Task[Int]]` in the same walk
reads that incomplete entry.

Probe `hole1.rig`: branch accepts, and it runs. `hole1b.rig` is the same program with Top's two fields
swapped, and the branch rejects it. `hole1c.rig` (`G[Task[Int]]` alone) is rejected. Main accepts all three.
```
obj G[T]
  v: T
  c: (*Chan[G[T]])?
  up: (?G[T])?
obj Top
  b: ?G[Int]
  a: G[Task[Int]]
... wait(<top)&      # accepted; `a.up` views a G whose Task is read on another core
```
The mirror case also exists: `(G, shares)` computed inside `(G, moves)` misses "T moves via chan". That
admits a `Syncs`-only `^{A + Syncs}` argument whose chan moves it.

Fix: store a held list only when its walk met no in-progress key other than its own frame. Otherwise drop
the entry after the walk so the next reach recomputes it. The alternative is to iterate the SCC to a
fixpoint (the lists only grow).

## 2. M1: mutually recursive or argument-swapping generics are now wrongly rejected (Medium; a regression)

`src/sema.zig:11471-11474`. For an in-progress instance whose arguments are not its own parameters in
position, every argument is walked both `.moves` and `.shares`. That treats a moved `Task` (or a
`Sends`-only API object) as shared.

- `a_mutual.rig`: `obj A[T]` (`v: T`, `b: ^B[T]?`) and `obj B[T]` (`a: ^A[T]?`), with `A[Task[Int]]`
  moved to a task.
- `b_swap.rig`: `obj P[X, Y]` (`next: ^P[Y, X]?`), with `P[Int, Task[Int]]` moved.

Main accepts both and runs them clean under `RIG_SANITIZE=1` (prints 5). The branch rejects both with
"holds `Task[Int]`". Per SPEC §18 every part sends, so these should be accepted. CHANGELOG does not list
them. The same fixpoint as issue 1 fixes this: map the in-progress declaration's eventual list onto the
arguments.

## 3. Pre-existing, the same class: `Walk`'s key omits `local` (Low)

`src/sema.zig:11219` (`WalkKey`) and `atomicReach` (chan elements walk with `local = false`).

In `n_chan_local.rig`, `obj Pair { g: G, c: *Chan[G] }` with `G` holding `*List[Int]` goes to a local task
and is accepted. Swap the fields (`n2_chan_order.rig`) and it is rejected. Main behaves the same. The
concurrency.md rule ("a channel's elements … must cross whoever holds the channel") requires rejection.
Fix: add `local` to `WalkKey`.

## 4. M5 is incomplete for generic instances with their own `Print` (Low; pre-existing)

`src/sema.zig:12531` (pn arguments pushed) runs before `12538` (the own-`Print` skip).

- `pr2.rig`: `obj G[T]: Print` with `b: T`. Printing a `G[[]U8]` is rejected with "the `[]U8` it holds
  would print as text".
- `pr3.rig`: `G[^{Shape}]` is rejected the same way.

Both are rejected on main and on the branch. Fix: check the declaration's own `Print` before pushing a
pn's arguments. The method body's own requirements already cover `T`.

## Checked and found sound

- **M1 siblings rejected as SPEC requires:** nested generics (`Outer[T]` holding `Inner[?T]`, and
  `Inner[T]` whose `U` is viewed), `W[...]?` in a plain object, `List[^W[...]]`, an imported generic,
  `W[^{Shape + Sends}]`, a generic enum payload, `W[?Task]`, a generic held by value and through a view,
  a generic function's `taskParams` through a nested instance, and a generic that views itself.
- **Accepted as they should be:** a recursive enum or object moved by value, `G[Int, Task]` with the
  viewed parameter `Int`, `W[*Cell[Int]]`, `W[*List]` (made local), and Map/Set/HashMap/List of tasks.
- **M2:** frames (two arrays of 7 MB → frame error), an object field `?Simd`, a generic body `[N of ?x]`,
  `R[Simd]` with `r: ?T`, and `?[]Int` arrays are all now rejected with correct byte counts.
- **M3:** a generic payload enum, an enum held by an object that names `E?`, an imported enum, and an enum
  reached through a generic instance are all rejected. Main fails in Zig ("dependency loop") on each.
  A payload-free enum is still accepted.
- **M5/M6:** `print`, `warn`, `List[B]`, `B?`, `?B`, `Map[Int, B]`, a generic `show`, and array print of a
  self-printing `B` holding `[]U8` all run.
- **HeldParts:** I checked all ten rewritten walkers arm by arm against main. Each gives the same answer
  (in `taskIn` the order changed, but it returns a bool). `unprintedIn` changes only by the intended
  M5/M6 differences.
- **S1:** the global `TableOrigins` is safe. A failed writer leaves `writing`, and later modules then
  compute their own. The count is 22 of `max_members = 32`.
