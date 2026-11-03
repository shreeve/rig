# Design and soundness expert: keep or cut (2026-10-28)

Probes: `rig` at origin/main (fe8246ca6), sources in
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-practical-hypatia-3af8bd/dbe54b0f-c953-450b-9882-0ae1b99f5bc5/scratchpad/fc/`.

| Candidate | Verdict | Default | Reason |
|---|---|---|---|
| `~T`, `~x`, `\|~x\|`, `*w` | **keep** | keep | The only thing that breaks a `*T` cycle (SPEC §9 "Cycles"). `w1.rig`, two nodes pointing at each other through `*Cell[*Node?]`, leaks 4 allocations; `w2.rig`, with a `~Node` back edge, drops both. `Table` ids can't stand in for it: a Table never shrinks and has no generations, so an id can't tell that its value is gone. Explicit teardown leaks silently the day someone forgets it. |
| `^{A}` | **keep** | keep | The only owning open set. `a1` (`List[^{Shape}]`) works. `a2` (`?{A}` only) needs one owner List per concrete type kept beside the views. `a3` (an enum) works but is closed: a library's API can't take a user's type. |
| `*{A}` | **keep but freeze** | keep | It completes the rule "`{A}` stands behind any holding sigil". A cut turns that one rule into an exception. Built 2026-10-23, so zero use says nothing yet. |
| `*{A + Syncs}` | **keep** | keep | The only open set shared across tasks beyond one scope. `*Frozen[List[^{A + Syncs}]]` is rejected (`s1`: "freeze the value before erasing it"). Inside a scope, `?xs` lent to tasks already works (`s3`). |
| `~{A}` | **keep but freeze** | keep | Observers of mixed type. Cheap once `*{A}` exists (a table entry). A cut adds a second exception. |
| `*Frozen[T]` | **keep** | keep | Rig's only `Arc`, built 2026-10-22. `f1` (an actor hands out one page that two tasks read) runs. `f2` with `*String` is rejected ("count is not atomic"). Replacing it with "count a `*T` atomically when it crosses" makes the cost a whole-program fact no one can see in the source: against effects staying visible (North Star 3) and against Trig's speed. |
| `once ?fun` | **keep but freeze** | keep | Rig's only FnOnce: a closure that moves its capture out. `o2` (plain `?fun`) is rejected ("the closure keeps what it captures for every call"). A fold into `(<t).within(ns)` removes the one std use and loses the general form. std uses it too little: `Map.ensure_with`'s `make` runs at most once and could be `once`, so a moved value could go in. |
| `^T` | **keep** | keep | Owned recursive types that can change. `t3` (a BST through `^Node?`) inserts in place. `t4` (Table ids) works but is fixed-size and can't delete. `*Node?` is read-only. `List[Node]` suits only n-ary trees. `^{A}` and `^[n of x]` build on it too. |
| `api`, `add T: A` | **keep but freeze** | keep | Agree with the census framing. `^{A}` and every bound depend on them. |

## Analysis

**Why use is low.** Two of the five were built in the last week: `*Frozen` on 10-22 and APIs Stage 5 (`*{A}`, `~{A}`, `*{A + Syncs}`) on 10-23. Trig is a compiler written arena-style that shares by loans (`?program`). These features serve GUIs (widget trees with parent back edges and observers), plugin registries, and servers (one cache page read by many tasks). Those are workloads Rig has not written yet, not ones it has rejected.

**Simpler or safer?** No cut removes a known weak spot. `docs/internals/weak-spots.md` lists against these features only `^T`'s forwarding gaps, which a cut of `^T` would replace with worse workarounds. Each cut would delete perhaps 50-200 compiler lines (by grep: `frozen` about 200, `weak` about 130, `once` about 45), but each also leaves a hole in a rule that is now uniform. With `~T` gone, the one leak SPEC admits ("Cycles") has no remedy in safe code. With `^T` gone, an owned tree that changes has no form. No cut unblocks a planned feature. Keeping them blocks nothing on the ROADMAP; the one open item, owned closures as objects of one method, is already gated by `bench/closures`.

**CORE.** None of the cuts fits CORE in a paragraph. Each one deletes something:
- `~T`: a row of §1 and half of sentence 8.
- `^T`, `^{A}`: §1's owning row, sentence 8, and §4's API-object paragraph.
- `*Frozen`: half of sentence 9, and the `*{A + Syncs}` list in §4.
- `*{A}`, `~{A}`: §4's paragraph that a panel and the owner approved on 10-23.
- `once`: the clause in §7.

So every cut is a CORE change under North Star 5, plus a list of programs a release accepted that would now be rejected. Keeping changes nothing.

**Freeze, concretely.** No new forms built on top of these: no `~` of a frozen value, no `*{A}` extensions past the ROADMAP. Their tests stay, and the oracle keeps covering them.

## Incidental findings (not cuts)

1. **The diagnostic for a self-containing type steers away from boxes.** For `left: Node?`, `t1` says "hold it through a shared handle (`*Node`)". It should suggest `^Node?`: a box owns its value and can change it in place. This may be part of why boxes show no use.
2. **`for x in ?h` is rejected over a `*List[Int]` and over a `*Frozen[List[...]]`.** The error is "cannot iterate over `*Frozen[List[Int]]`", though SPEC says `?f` lends a `?List` (`p2`). Iterating a frozen registry needs it (`s2`). This is a gap, not a soundness bug.
