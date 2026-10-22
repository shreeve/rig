# Review: hotfix-generic-payload (v0.2.1 candidate)

Branch `hotfix-generic-payload` in `/Users/shreeve/Data/Code/rig-hotfix7`,
7 commits on v0.2.0 (`44e0a9f7`), built with `zig build` (and `zig build
oracle`). Reviewed adversarially; nothing edited or committed.

Probes: `.git/revamp/r3/probes/review-hotfix7/` (79 programs; `both.sh`
runs each under `RIG_SANITIZE=1` with `rig-v020` and the hotfix, and
`out/probes-all.txt` holds every result; `out/probes-oracle.txt` holds
`bin/rig-oracle -v` over all of them).

## Verdict

No Critical, High, or Medium finding. Every claim checks out:

- The `match get(o)` / `.some(v) => v` use-after-free is fixed, and so
  are four sibling use-after-frees that v0.2.0 accepted and crashed on
  under the sanitizer: a nested `match <inner` of a call-view payload
  (`p13`), `|<v|` capture of a call-view payload (`p06`), a payload of a
  write view a call returns given back (`p22`), and `<v` inside a
  closure body (`p45`). Each is now rejected.
- No sanitizer failure from the hotfix binary across all 79 probes, 950
  behavior/example programs, and a 789-program corpus sample.
- Nothing that v0.2.0 accepted and ran correctly behaves differently, except
  the forms the PR lists as newly rejected (details under "Equivalence").

The findings below are all Low: a missed site that makes the checker reject
too much, and a few issues that predate the hotfix.

## Findings

### Low 1: one `alias_of` site missed: a nested match over a no-root payload view
`src/ownership.zig:4384` on `97bdcb19`, `:4475` after the rebase (`walkMatch`), still decides a nested match's `via`
by `v.alias_of != null`:

```zig
if (p.through_view or v.alias_of != null) info.via = .viewed;
```

When the outer binding is a `payload_view` with no `alias_of` (its subject
is a call view, a branch, or part of one), the inner match's bindings get
`via = .owned`. A tail `v` in a generic body then goes to `movePayload`'s
"write `match <inner`" error instead of recording the per-instance copy
requirement. The suggested `match <inner` is then also rejected.

- `p12_nested.rig` (outer `match get(o)`, inner `match inner`, `.some(v) => v`,
  `T = Int`): both binaries print
  `19:21: error: cannot move `v` out of `inner`: `match inner` reads `inner`; write `match <inner` to take its fields`.
- `p14_nested_place_text.rig`: the same program with the outer subject a
  place (`match o`) is accepted and prints `5`.
- `p13_nested_take.rig`: following the hint is rejected (`cannot move out of
  `inner`: it is a view of `get(o)``). v0.2.0 accepted it and crashed:
  `use of freed memory`.

The checker rejects more than it should, and the hint points the wrong way.
This is not unsound: `movePayload` always reports, whatever the `via`. The
behavior is unchanged from v0.2.0 for `p12`. It contradicts "every site now
reads `payload_view`". Fix: test `v.payload_view`. Then `via` is `.viewed`
(or `.shared`) for any binding that views, and the nested case matches the
place case.

### Low 2: `return v` vs a tail `v` of a generic payload (now also for call and branch subjects)
`p35_return_stmt.rig`, `T = Int`. The new binary rejects both functions:
`cannot move out of `v`: it is a view of `o`` (place: v0.2.0 already
rejected this) and `... a view of `get(o)`` (call: v0.2.0 accepted this and
ran it correctly at `T = Int`). A tail `v` in the same position is accepted,
with a per-instance `no_move` requirement (`consumeTailName` → `reportAlias`).
`walkReturnValue` → `returnMoves` → `moveVar` → `movePayload` rejects for
every instance instead. This rejection is intended: `generic_payload_view_moved.rig`
(`returned`) pins it. It is a newly rejected v0.2.0 program that was sound
at a plain `T`. The oracle calls both functions `stricter`. Worth one line
in the release notes. Better: have `return v` take the tail path for a
`payload_view`.

### Low 3 (predates the hotfix): the oracle disagrees with the compiler on a generic `if … as` copy that is moved
`p26_as_move.rig`: `if getw(w).p as v` / `return take(<v)`, and the same with
`if w.p as v`. The compiler accepts the generic body: the `as` binding is an
owned copy with a `no_move` requirement, and the `Text` instance is
rejected. The oracle reports
`DIFF a1 prod=accept ref=reject C7 a payload seen through a view does not move out`.
This is sound, because every accepted instance is plain data. But it is
exactly the shape test/README says can never be allowlisted, so adding it as
a test would fail `oracle/tests`. The hotfix did not touch this (both
binaries give the same output).

### Low 4 (predates the hotfix, sibling of `not_function`): `*T` at a view type
`f04_handle_of_view_inst.rig`: `struct H[T] h: *T`, then `x: H[?Int] = H(h: *(?n))`.
Both binaries accept it and print `5`, yet `*?Int` written out is rejected
("a handle holds a value, not a view"). Loans still flow (`f07` and `f08`
reject the dangling forms), so I found no unsoundness. It is the same class
the new requirement fixes, though: an instance makes a `*T` that the instance
could not write. Consider a `not_view` requirement next to `not_function`
(generic types without methods may take view arguments).

### Low 5 (predates the hotfix, hints)
- The box-match hint suggests `match ?mkb(<x)` (`p46`), which is then
  rejected: "this header binds a copy of its subject" (`p47`).
- The new weak-upgrade hint always names the lent handle `w` (and the
  upgrade `s`), even when the scope already has a `w` or `s`
  (`w04_hint_name_clash.rig`). Applying it literally fails
  (`w05_hint_applied.rig`: "`w` is already a `Int`"). This is cosmetic.

### Note (oracle, not compiler)
`p36_mutate_subject_while_view.rig` (`m1`, `m3`): `match get(?o)` /
`.some(v)`, then `o = .nothing` and `print(v)`. The compiler rejects this
correctly ("cannot reassign `o` while it is lent"), but the oracle accepts
it (`stricter`). That looks like an oracle gap in generic payload views (the
oracle models the payload as a copy), so it is worth an oracle test.

## Claim by claim

### 1. `Var.payload_view` (commit 8b6a3d14)
I audited every remaining read of `alias_of`:
- `findLoan` skip: correct; it is about the scrutinee root.
- `writesThroughLocal`: correct. It applies to write mode only, where the
  bindings have `ref == .write` and are never `payload_view` without a root.
  The `p28` and `p29` stores are rejected either way.
- `movePayload` root lookup: correct; it returns early when there is no root,
  but `via` is never `.owned` there.
- `walkMatch:4384`: missed (Low 1).

The sites that now read `payload_view` (owns/liveness, `consumeTailName`,
`lendOn`, `moveVar`, `walkDrop`, reassign, `returnMoves`, `checkDropOrder`)
are each consistent with emit. Emit decides binding ownership only by
`storage.matchMode`, which `takesSubject` reads, and in read mode it never
drops a binding. A read-mode binding with no root and `!readsInPlace` (a
made, non-view value) is "owned" in the checker. That is reached only
through `cannotCopy` → `.depends` → `no_move`, so the instance is plain and
nothing leaks.

Subjects attacked, with `T` = Int, Text, `*S`, a Cell holder, a `unique`
struct, `Box[Int]`, `Vec[Int]`, and `!Vec[Int]`:
- place, lend, call view, lend of a call view, branch, branch of calls
- field and element of each; part of a made value
- guarded arms, catch-all, nested matches
- a write view a call returns, a boxed enum through a view
- `match <x`, `match <mk()`, `match mk()`

Payload uses attacked:
- returned, moved, dropped, reassigned
- captured (`|<v|`, `|?v|`, `|+v|`), deferred
- passed by value; pushed, stored in a field, `replace`d
- put in a constructor, an array, a `Box`, or behind `*v`
- `replace(!v, …)` through `match !getm(!o)`
- returned as a view `?v` (rejected by `arm_view`)

Every owning instance is rejected or runs clean, and the taken forms (`p34`:
`_` payloads, guards, unused payloads, whole) run clean with Text.

The new catch-all `no_cell` requirement fixes a real v0.2.0 bug.
`p41_catchall_local_emit.rig` (generic `match w.o` / `x => f(?x)`, bumping
a Cell) printed `0` under v0.2.0: the emitted `else => |x|` is a by-value
copy, and the Cell change was lost. The hotfix now rejects it at `T = C`.

`if … as`, `while … as`, and `for` are unchanged; they bind owned copies
with a `no_move` requirement (`p25`, `p26`, `p42`).

### 2. Box of a handle (a65b7eb1, 3018c4ac)
- Reads work, where v0.2.0 failed Zig compilation (`**RcBox ... does not
  support field access`), through: `Box[*S]`, `Box[Box[*S]]`,
  `Box[*Box[*S]]`, `*Box[*S]`, `?Box[*S]`, `!Box[*S]`, a field of a struct,
  an element of a `Vec`, an optional, and a generic `Box[*P[T]]`.
- They work in closures, `defer`, `if … as`, `for`, slices, guarded
  matches, `Box[*Vec[Int]].len`, and `Box[*Text]` (`b02`–`b04`, `b06`).
- Writes are rejected in every form (`b01`, `b05`, `b07`): field assign
  (also via `!Box[*S]` params, struct fields, Vec elements, and `if … as`),
  `replace(!b.t)`, `match !b.k`, `for x in !b.xs`, `!bv.push`, and generic.
- `!bv.push(1)` on `Box[*Vec[Int]]` passed v0.2.0's checks (it then failed
  in Zig); it is now rejected.
- Box's own methods are excluded from the receiver rule (`<bb.unbox()` on
  `Box[Box[*S]]` still works).

### 3. Weak upgrade hint (229d7b94)
Each suggested form compiles and runs: box, `?Box`, `!Box`, `Box[Box[~S]]`,
`*~S`, `*Box[~S]` (`w02`). A direct field or element weak keeps the old hint
(`w03`). Cosmetic name clash: Low 5.

### 4. `not_function` (7ca5afb8)
- Covered: `~T` (`f06` failed Zig compilation in v0.2.0 and is now
  rejected), spelled `*T`/`~T`, `*x` made in a body, nested instances, and
  typeArgs.
- Not over-rejected: `*T` at `T = *fun` (handle of an owned closure, `f02`),
  at `(fun)?`, at a struct holding a function, and at `[2]fun` (`f09`); also
  `T?`/`?T` at a function type (`f01`).
- Sibling class: Low 4.

### 5. Argument write loans (bb8c5998)
The port is byte-identical to round C's `e8dc7278`. Siblings are rejected
in both binaries:
- receiver plus argument (`!b.firstw().addfrom(?b)`, `.addn(grow(!b))`)
- a later argument that grows the Vec (`pair(!b.firstw(), grow(!b))`)
- `print` (`a01`)
- a write-view parameter root (`a02`)

The one new rejection (`a02` `viaparam`: `pair(!b.firstw(), count(?b))` with
`b: !Bag`) is the fixed hole. Copying a value out (`!b.firstw().n`) is still
accepted.

### 6. `*none` (97bdcb19)
- Rejected: `*none` and `*(none)` where no `*(T?)` is expected (`n01`).
- Still accepted and run correctly (`n02`):
  - a `*(T?)` binding, argument, return, or `Vec[*(T?)]` element
  - `*(Int?)?`
  - `takesg[Int?](*none)`

## Equivalence (v0.2.0 vs hotfix, `RIG_SANITIZE=1 rig run`)
Run via `cpuq` (`out/run-beh.txt`, `out/run-corpus.txt`; `runcmp.sh`):

- **test/behavior and examples, 950 programs.** One real difference:
  `types/box_of_handle_access.rig`, the new test, which v0.2.0 cannot compile.
  The 32 other diff blocks are only panic thread ids.
- **Corpus sample, every 8th file, 789 programs.** Two real differences,
  both new hotfix files: `b4a-generic-view-call-payload-copy.rig` and
  `holding-box-of-handle-field.rig`.
- **`test/equiv.py` against main, all sections (`out/equiv-main-vs-rebased.txt`).**
  `0128c295` vs the rebased hotfix (both built into the scratchpad copies
  that the run used): 8296 programs, **14 differ, every one of them a file
  the hotfix adds**. Only `box_of_handle_access.rig` and
  `holding-box-of-handle-field.rig` differ in `emit`.
- **`test/equiv.py` against v0.2.0 (`out/equiv.txt`).** 27 differ: the same
  new files, plus 12 existing rejected programs whose diagnostics main's
  c-rules work changed. Two kinds of change: (1) the note text "lent to
  write here, as the receiver, which is read until the call starts"; (2) a
  duplicate "use of `a` while a write loan is live" is gone. Note: the
  binary changed partway through this run (see "Target moved"), so use the
  main-vs-rebased run as the clean result.

## Target moved during the review
At 02:26 the branch was rebased onto `origin/main` `0128c295` (c-rules,
PR #52). The rebased branch:
- drops bb8c5998 (main already has round C's `e8dc7278`, which
  `bb8c5998` copied exactly);
- adds `f451f790` (tests only);
- rebuilt `bin/rig` at 02:26:54.

What was checked against what:
- All probes and both `RIG_SANITIZE` run comparisons ran on the original
  7-commit branch (binary from `97bdcb19`).
- The `src/` diff of the rebased branch against main equals the original
  diff minus the argument-loan lines.
- I re-ran all 79 probes on the rebased binary against a main build
  (`both-rebased.sh`, `out/probes-rebased.txt`). Every result matches the
  pre-rebase one. The only differences are main's new note text in
  `a01` and `a02`.
- The findings above hold for the rebased branch.

v0.2.1 is now v0.2.0 + c-rules + this hotfix. The release notes should
also cover c-rules' user-visible changes, which are diagnostic-only on the
tracked programs.

Newly rejected forms (all sound to reject, and all pinned by the branch's
tests):
- a call, branch, or part payload moved, dropped, returned by `return`, or
  reassigned
- a generic catch-all copy at a Cell holder
- writes through a box of a handle
- a `*T`/`~T` instance at a function type
- `*none`
- a later argument that reads a root a write-view argument holds
