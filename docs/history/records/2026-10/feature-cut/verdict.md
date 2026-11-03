# Keep or cut: the panel's combined verdict (2026-10-28)

Three experts reviewed the candidates the usage census flagged: [expert-cost.md](expert-cost.md), [expert-design.md](expert-design.md), [expert-users.md](expert-users.md). No repository file was changed.

**Unanimous: cut nothing.** Each candidate is the only way to do something safe Rig needs, so zero uses in Trig, which is arena-style, say little about other programs.

| Feature | Verdict | Why it stays |
|---|---|---|
| Weak handles `~T`, `\|~x\|` | **Keep** | The only fix for the one leak safe Rig admits, a cycle of `*T` (confirmed by probe). Table ids can't stand in, since a Table never shrinks and has no generations. Learn 01/02 and the launch post teach `~x`, and two examples use `\|~x\|` (the census missed them). |
| `^{A}` (owned API object) | **Keep** | The mixed-type list, which is the API demo in README and Learn 04/08; plugins and handlers. Cheap: about 200 lines, mostly shared with boxes. |
| `*Frozen[T]` and `*{A + Syncs}` | **Keep** | Rig's only cross-task sharing: a server's config across requests, Rust's `Arc<Config>`. Built on 10-22 and 10-23, so a week of no uses proves nothing. |
| Boxes `^T` | **Keep** | The only owner of a recursive type that changes in place, such as a tree; `examples/tree.rig`. The Lean model's one owner kind is `^Int`. |
| `*{A}`, `~{A}` | **Keep, freeze** | Rare, but cutting them would break the one rule that `{A}` can sit behind any holding sigil. About 400 lines, and three past fixes of programs wrongly accepted. |
| `once ?fun` | **Keep, freeze** (design, users) or **fold into a std-only attribute** (cost) | It's the only closure that can move a capture out. std could use it more: `ensure_with`'s `make` is called once. |
| User `api` / `add` | **Keep, freeze** | `^{A}` and the built-in APIs need them; only their unbuilt stages wait. |

A cut would need almost no migration. Its cost would be rewriting about 125 test cases and the docs, plus a CORE review, for little gain.

## What the panel found instead (fixes, not cuts)
1. **Every `*T` pays for weak handles.** Each counted allocation carries a weak count (8 bytes) and does a second decrement on its last drop, even when no weak handle is ever made.
2. **`*Frozen` carries that weak count, though it can never have a weak handle.** It can be dropped with no cut and no change to any program.
3. **A misleading message.** A type that contains itself is told to use `*Node`, a shared handle. For a tree the right fix is a box, `^Node?`. That may be why boxes go unused.
4. **A bug:** `for x in ?h` is rejected when `h` is a `*List` or a `*Frozen[List]`.

## Decisions for the owner (defaults first)
1. **Cut nothing; freeze `*{A}`, `~{A}`, `once ?fun` and user `api`/`add`,** meaning no new stages or forms until a program needs one. [yes]
2. **Drop `*Frozen`'s weak count.** [yes, a small PR]
3. **Fix the self-containing type message to suggest `^Node?`, and accept `for x in ?h` over `*List` and `*Frozen[List]`.** [yes]
4. **Measure what the weak count costs every `*T` on Trig** (28 uses), by share first, before changing how weak counts are stored. [yes, measure only]
5. **`once ?fun`:** keep it as is, with std using it where a closure is called once, or fold it into a std-only attribute. [keep]
