# Expert: cost

What each candidate costs to keep, and what a cut would cost, measured on origin/main (fe8246ca6). Nothing in any repository was changed.

## Verdicts

| Candidate | Verdict | Default | Reason (cost) |
|---|---|---|---|
| Weak `~T`, `~x`, `\|~x\|`, `*w` | **keep but freeze** | freeze; drop the weak word from `*Frozen` now | About 600 compiler lines and 125 cases, cheap to keep. The real cost is at run time: every `*T` allocation carries a weak count (8 bytes) and does a second decrement on its last drop. It is the only remedy SPEC names for cycles, and I confirmed one leaks in safe Rig |
| API holding forms `^{A}` / `*{A}` / `~{A}` | **keep `^{A}`; keep but freeze `*{A}`/`~{A}`** | freeze | `^{A}` adds about 200 lines, mostly shared with `^T`, and makes `List[^{Shape}]` possible. `*{A}`/`~{A}` cost about 400 lines (three runtime tables, `eraseShared`) and three past *unsound* fixes. Cutting them means rewriting about 100 cases and the bench `bench/apis/shared.rig` |
| `*Frozen[T]` | **keep but freeze** | freeze | About 350 lines, 54 cases, 7 doc blocks. Its defects sat where it meets weak handles and the `Syncs` bound. Cutting it also cuts `*{A + Syncs}`, its only source, so the cut grows |
| `once ?fun` | **fold** | make it an attribute only std may write; keep the rule | About 250 lines (mostly ownership `walkFunOnce`/`onceUses`), 11 cases, no defects on record. `time.within(d, \|<t\| >t!)` depends on it, so the rule has to stay. Only the user-facing spelling goes |
| Boxes `^T` | **keep** | keep | The most shared of the five (about 850 lines, 554 cases, 27 doc blocks). It is the only owner a recursive type can hold mutably (`examples/tree.rig`, `^Node?`), and λRig's one owner kind is `^Int`. A cut would rework the Core, the proofs and the tests |
| User `api` / `add T: A` | **keep but freeze** | freeze | 379 cases, 58 doc blocks, and Stages 1 to 5 of docs/design/apis.md. Generic bounds and views share it, so it cannot be cut piecemeal |

## Measurements

The compiler counts cover the eight named files plus `rig.zig`, 76,906 lines in all. **Own** means functions named for the feature, or with at least 25% of their lines about it. **Shared** means lines elsewhere that name it. A cut removes the own lines plus about 1.5 times the shared lines.

| | weak | Frozen | once | `^T` | API holding |
|---|---|---|---|---|---|
| Compiler, own / shared | 260 / 250 | 200 / 115 | 157 / 75 | 266 / 380 | ~520 / ~200 (runtime 320) |
| Grammar productions | 5 (`~` type, expr, cap) | 0 (built-in name) | 3 | 4 | shared with `{A}` |
| Oracle | ~45 lines (kinds, lower) | 4 | 1 | ~20 | ~27 |
| Formal (Lean) | none | none (Crossing.lean, in a comment) | none | the model's owner (`^Int`), all of Steps/Sound | Erase.lean `ObjKind.box`; Crossing.lean |
| Test cases (of 9,260) | 125 | 54 | 11 | 554 | 186 (views: 101) |
| Doc `rig` blocks (of 938) | 15 | 7 | 2 | 27 | 24 |
| SPEC | §9 Weak handles and Cycles (~83 lines) | Frozen values (~62) | Closures called once (~43) | Boxes (~140) | inside API objects (~510); shared/weak ~85 |
| CORE | §1 row clause; s8's last sentence and its example (~22); §4 `~{A}`, "no `~`", example (~27); §7 `~x` | s9's middle (~6 sentences); a §4 bullet; 2 examples | §7, one sentence | §1 rows, s8, §4/§5 throughout | §4 ~150 lines, 4 examples |

The weak and API-holding columns overlap: `ApiWeak` and the weak table entries, about 85 runtime lines, count in both.

**Defects on record.**
- **Weak:** a `~T` of a frozen value emitted a Zig error (apis-stage5/review-p2). The Stage 5 adversary found that SPEC promised "a frozen value has no weak handle" while the runtime enforced nothing of the kind. The backlog still lists `T = ~U` stacking at generic instances (pending in SPEC). weak-spots lists the upgrade through `^~T`.
- **API holding:** the Stage 5 entry in the CHANGELOG fixed three unsound accepts: `^Wrap[Tok]` into `^{Shape}` cloned a unique value, a box of `Owned` outlived its view, and a box of `Sends` carried a `*Int` to another core.
- **`^T`:** weak-spots lists indexing, `for`, `==` and arithmetic that do not forward through a box, and `unbox` hiding a method of the same name. The backlog has the shorthand through a box and the deep clone of `^T` in a generic body.
- **Frozen:** the weak-handle hole above, and `*Frozen` ordering (#587).
- **once:** none.

## What a cut costs

- **Migration is nearly free for every candidate.** Trig, std and examples use none of them except `time.within` (`once`), `examples/tree.rig` (`^T`) and `bench/apis` (`*{A}`). Each cut still rejects programs a release accepted, so it needs a release-notes list and a one-line note to Trig (AGENTS).
- **Most of a cut's cost is rewriting tests and docs.** Each removed case or block shifts entries in the oracle's `rejections` and `coverage`. Weak, Frozen and the holding forms are ownership rules, so each cut needs a CORE review with 4 to 7 experts and the owner's approval (North Star 5).
- **The wins are small.** Cutting weak removes about 1% of the compiler, the second count on every `*T` (8 bytes per allocation; less work when an atomic handle drops), the `~` token, and several "no `~`" rules in Frozen and `*{A + Syncs}`. That run-time saving is the only one any cut offers, and it would have to be measured on Trig under the speed bar. The smaller version is free with no cut: `*Frozen` can never have a weak handle, yet it still carries the weak word.
- **One leak stays in safe Rig either way.** A `*Cell[*N?]` cycle leaks (probed: "4 allocations (128 bytes) never freed"). Without weak handles, the only fix is to clear the cycle by hand.
