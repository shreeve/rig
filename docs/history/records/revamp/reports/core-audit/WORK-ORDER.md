# Realizing the Rig Core: gap map and work order

This plan comes from six audits of `main` (dd36c78) and the strings branch
(`text-core`), checked against the Rig Core draft. The full reports are in
this folder: `kinds.md`, `reads.md`, `loans.md`, `containers.md`, `emit.md`
and `docs.md`. Together they ran about 450 probe programs, all under the
sanitizer.

## Bottom line

- **The Core is realizable, and it mostly makes the compiler smaller.**
  Every structural change the audits designed either deletes code or is
  close to flat. The proxies, duplicated classifiers and position lists the
  Core replaces are where the bugs have been.
- **Two live memory-safety holes on `main`** were found and confirmed.
  Both are being fixed now, as classes.
- **Changing to the Core never changes the meaning of an accepted
  program.** Every Core rule is either already true, or turns a rejection
  into an acceptance. The two exceptions are decisions you make
  deliberately: decision 3 (failing must be written) and decision 6 (the
  Bool long form).

## Live bugs (fix first)

| # | Bug | Found by | Status |
|---|---|---|---|
| B1 | A `defer`/`errdefer` that reassigns or re-borrows leaks its effect past an `e!`, `e?` or fallible-tail exit, so a moved value looks alive and is read after it is freed. A regression from the safety-net PR (04bb8835). | loans | hotfix in progress |
| B2 | `print(c, grow(?c))` copies a `Cell`'s contents before a later argument changes them, so `print` reads freed memory. The plain-data form prints a stale value. The strings branch's `Text(...)`/`add` have the same bug. | emit | queued on the same hotfix branch |
| B3 | A local `w = <w2` (with `w` a write borrow) silently ignores the move and writes through. | containers | small fix |
| B4 | `h = *[1, 2]` then `h[0]` is accepted, but the Zig does not compile. | loans | small fix |
| B5 | A statement `-f()` silently negates and throws the result away. | emit | small fix (reject it) |
| B6 | On the strings branch: `for x in h.o?` double-frees. `main` already fixed this; it comes back unless the branch merges `main` correctly. | reads | handled when strings land |

## Work order

Only one branch at a time touches `ownership.zig` or typecheck's
classification. Each step lands as one PR, and passes the suite, the full
corpus and the sanitizer.

1. **Hotfix B1 + B2** (in progress), then **B3–B5** as one small PR.
2. **Core v2 and your decisions** (no code). Then commit `docs/CORE.md`
   with a "pending" doc-example kind: a pending example must fail today, and
   becomes a normal test once it passes.
3. **Land strings.**
   - Merge `main` into `text-core`. Keep main's defer fix, its `for`-source
     rule and the sanitizer text; the branch's diff wrongly appears to
     delete them.
   - Cut temporaries back to Core §3: delete `handsOverFresh`,
     `rejectNotFresh`, the header extension, the while resets and the hidden
     match subject. That is about −75 lines.
   - Fix `Text(...)`/`add` for B2.
   - Run the corpus and the sanitizer.
4. **Type facts.**
   - C1: one `copyable` fact replaces five disagreeing rules (about 40
     sites). It fixes false rejections such as `<p` on a plain match payload,
     and a plain field move. About −40/+15 lines.
   - C2: one `unique` fact, declared (decision 1) or inferred from a held
     `Cell` (decision 2). The `Rng` empty-drop hack and six fork patches go.
     About −60/+30 lines.
5. **One classifier and one exit.**
   - `handsOver` (place, made value, lend, view, branches, jump) replaces
     five classifiers that disagree in 12 places.
   - `exitTo` becomes the only way a path ends, so it never forgets a loan.
     It replaces about 20 sites, at about +90/−70 lines.
   - These close weak spots W1 and W2 from the root-cause report.
6. **Reads and lends** (Core sentence 1 and §4).
   - A bare name only reads; this turns rejections into acceptances.
   - One `lendsAs` table replaces six conversions, about −80 lines. That
     brings `sort.sort(!v)`, Box and handle members, `for` over a Text, and
     `?Shape` serving a `Box[Shape]` and a `*Shape`.
7. **Containers hold anything** (§5), and **one `=` on borrow places**
   (decision 4, one `assignMode` fact).
   - Remove about 6 early rejections: `Vec[Text]`, `Vec[Vec]`, records that
     own strings, `!v[i]`, `<v[i]`.
   - About 150–300 lines. Map and Set become writable in Rig.
8. **The small decisions.**
   - Decision 3, "an error meets `T!` only as `return`'s operand": about 20
     lines; newly rejects 2 tests.
   - Decision 6, the Bool long form: 2 lines, and deletes about 45.
   - Decision 5, `=!` to a keyword: a mechanical rewrite of about 135 files.
9. **Lives-for-the-whole-program and better borrow origins** (sentence 7).
   - Per-function "must be static" parameter summaries (about 300–500
     lines). This unlocks a generic `Holder[String]` with literals, and
     String parameters stored in a `Cell`.
   - The signature-only origin refinement (about 100–150 lines), which ends
     over-borrowing such as an `!Int` counter being locked by an unrelated
     result.
10. **Docs.**
    - Rewrite SPEC around the Core: about −20%, and the 65 exception lists
      become derivations.
    - WELCOME teaches the four kinds through Python/Ruby habits.
    - Fix the 22 false claims.
11. **Speed.** Two quadratic generic checks take 63% of `rig check` at 48k
    lines. Index generic frames by their declaration.
12. **Lowering** (L0–L6, 4–6 weeks). Decide after step 7 whether the
    remaining bug rate justifies it. L0 ("settle each fact once") is cheap,
    and folds into steps 4–6.

**Then unfreeze features:** io, fs and Map, each first written as a
paragraph that fits the Core.

## Decisions for you

The six from the Core draft, restated with what the audits found:

1. **A word for a move-only type** (`struct Rng unique`). It is the same
   change as decision 2 (one `unique` fact). Lean: yes.
2. **A type holding a `Cell` (or a bare `Cell[T]`) is not copyable.** The
   audits found silent state forks through bare binds, `+a`, field reads,
   arrays and generics, patched in six places. Lean: yes. About 150 test
   files hold a Cell by value; most only need `<`.
3. **Failing is always written.** The rule: an error value meets `T!` only
   as the operand of `return`. It is wider than "the last line": ternary
   branches, match arms, `break E.x`, closure tails and fields all fail
   silently today. It was prototyped in 20 lines and newly rejects 2 tests,
   9 corpus probes and no doc examples. Lean: yes.
4. **One `=` on borrow places.** Assigning a borrow re-points; assigning a
   value writes through; locals and fields behave alike. Today they differ
   four ways, and one of those is bug B3. Lean: yes.
5. **`=!` becomes a keyword** (`fix x = e`). It is a mechanical rewrite of
   about 135 files, and `fix` is unused as a name. Lean: yes.
6. **The Bool long form** (`dup = (!s).insert(1)`) wherever the value is
   used. It is a 2-line change and deletes about 45 lines. Lean: yes.

New, from the audits:

7. **`return x` and a tail `x` move a bare owner.** Sentence 1 says a bare
   name never moves. Options:
   - (a) state the one exception: returning, or ending a function or block
     with an owner, moves it, because it is always the last use. `break x`
     then follows the same rule, and today's `break <x` requirement goes.
   - (b) require `return <x` everywhere.

   Lean: (a).
8. **Sentence 10's `??` is not a failure handler.** The Core will say
   "`!` or `catch`". This is a correction, not a choice, and is listed so
   you see it.
