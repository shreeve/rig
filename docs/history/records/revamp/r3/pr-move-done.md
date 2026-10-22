# `<` always leaves its source done

Branch `move-done` at 19bec64d, on main c169ec89 (v0.2.4), with main cdc17232 (#66, docs only) merged in; doc and vocab checks pass on the merge. Four commits:
the rule (1738234f), its docs (a82ee668), the round-2 fixes after the
first independent review (c1a7d3f4), which close the class, and the
round-3 consistency fixes after the second review (19bec64d), which
found no soundness hole.

## The rule

`<` always leaves its source done: a name is ended, an optional field or
element of a place is emptied to `none`, and `<` on any other source is
rejected.

Before, `<` on a field or element whose value copies (`<s.n`, `<v[0]`,
`<s.p` of a plain struct, `<(?s).n`, `<h.n` through a `*T`, a
`for x in <s.arr` source) copied it and left the source usable, unlike
`<n` on a local. The same held for a branching value whose leaf is a
name or a part (`<(n if c else 5)`, `<(o ?? n)`, `<o?`, and `<s.o?`,
which neither emptied `s.o` nor was rejected), for a part of a value
made in the statement (`<mk().n`), for another module's constant or a function
(`<geo.K`, `<one`), and for a closure's copy capture (`|+n| twice(<n)`
left the closure's `n` as it was for the next call).

The rejections read as one rule:

```
cannot move out of `s.n`: it copies, so `<` would leave it as it was; remove the `<` to copy it
cannot move out of `s.v`: `s` would still drop it (partial moves are not supported); move `s` whole, or exchange the field: `replace(!s.v, v)`
cannot move a part out of the temporary `mk()`, which its statement drops; bind it to a name first
`<` here would copy `o` out without moving it; move it before the `?` or `!`: `(<o)?`
`<` here would leave `s.n` as it was: it copies; remove the `<` to copy it
cannot move function `one`: a function lives for the whole program; remove the `<` to use it
```

## Breaking change

A program that writes `<` where it cannot leave the source done no
longer compiles:

| Before (accepted) | After | Fix |
|---|---|---|
| `m = <s.n`, `eat(<v[0])`, `<h.n`, `for x in <s.arr` | "cannot move out of `s.n`: it copies, …" | **remove the `<`**: `m = s.n` copies it, as `<s.n` did |
| `<(n if c else 5)`, `<(o ?? n)` | "`<` here would copy `n` out without moving it; move it inside the branch: `<n`" | move the leaf where it is: `<n if c else 5`, or remove the `<` |
| `x = <o?`, `y = <s.o?` | "… move it before the `?`: `(<o)?`" | `(<o)?`, `(<s.o)?` (which now empties `s.o`) |
| `<mk().n` | "cannot move out of `mk().n`: it copies, …" | remove the `<` |
| `<geo.K`, `<one` | "cannot move module-level `geo.K` …", "cannot move function `one` …" | remove the `<` |
| `\|+n\| twice(<n)` | "cannot move `n`, a copy capture: the closure keeps it for every call; remove the `<` to copy it" | remove the `<` |
| `<(!mk()).o`, `<gw(!mk()).o` | "cannot take out of a temporary: nothing would see it emptied" | bind the value to a name first |
| `<s.p.into()` (`into(<self)` on a part that copies) | "cannot move out of `s.p`: it copies, …" | **remove the `<`**: `s.p.into()` now takes a copy (below) |

Before:

```rig
struct S
  n: Int

sub main
  s = S(n: 1)
  m = <s.n
  print(m, s.n)
```

After: `error: cannot move out of `s.n`: it copies, so `<` would leave it as it was; remove the `<` to copy it`. Write `m = s.n`.

Unchanged: `<n` on a local ends it; `<s.o` and `<v[i]` of an optional
take it, leaving `none`; an owning field stays rejected.

Also new, in the other direction: **a method that consumes its receiver
takes a copy of a receiver whose value copies**, as an argument does
(`s.p.into()`, `v[0].into()`, `p.into()` of a plain local, and
`p.into()` through `p: ?P` or `p: !P`). Before, it required `<`, or was
rejected through a view, and `<` on a part is now rejected. `<p.into()`
still moves a local.

**Wording:** every sigil hint says "remove the `<`" (and `!`, `*`, `:`,
`;`), not "drop", which in Rig means destroying a value. 29 rejected
programs' messages change only in that word.

In this repository the rule changed 13 programs from accepted to
rejected, none in examples/, std/, or the docs: 6 behavior tests and 7
corpus probes (survey: `.git/revamp/r3/survey-move-done.md`).

## One classification: `sema.moveSource`

What `<` does to its source is decided once, in `src/sema.zig` beside
`handsOver`, by a positive list over `handsOver`, the operand's type, and
its root's symbol:

| `MoveSource` | Source | Who acts on it |
|---|---|---|
| `binding` | a local or parameter | ownership: ended (`moveVar`) |
| `capture` | a closure's capture, of any kind | ownership: rejected, since the closure keeps it for every call |
| `optional_part` | an optional field or element of a place, also through a view (`<(!s).o`, `<(!s if c else !t).o`) | typecheck records `takes` and checks the place may be written; ownership `walkTake` |
| `part` | any other field or element of a place | ownership `movePart`: rejected |
| `branch_part` | a field or element of a branching value (`(a if c else b).v`, `(o ?? a).v`, `o?.a`) | ownership `movePart`: rejected |
| `made_part` | a field or element of a value made in the statement, and an optional one reached through a lend or a call's view result of such a value (`<(!mk()).o`) | typecheck `rejectMadeParts`: rejected |
| `declared` | a function, or a module's constant or part of one | ownership `moveDeclared`: rejected |
| `made` | a value made there, a lend, an enum variant, a `match` or block | taken |
| `branches` | `if`/`else`, `??`, `catch`, `e!`, `e?` | each leaf (`sema.moveLeaves`): a made leaf is taken; any other is rejected where it is, made parts by typecheck, the rest by ownership |

Every carrier asks it: `<e` wherever it stands (binding, argument,
`return`, `break`, constructor and array operands, `match` and `if … as`
subjects, `*<`, a consuming receiver, `defer`, closures), and the
`for x in <e` source, which has no `<` node. The checkers report where
each kind was already reported, so diagnostics of already-rejected
programs do not move between passes.

**Sites that used to decide it, and where they stand:**

- typecheck `synthMove` → `tempBase` + `needsCleanup` ("a part of a
  temporary"): removed; it is `made_part`. This is what missed the `for`
  source (C1) and the branch leaves (C2).
- ownership `movedTail`/`ownsPlace` (branch leaves that own) and its own
  place/view/branch walk: removed; `walkMove` switches on the fact.
- typecheck records `takes` only for `optional_part`. Its access check
  (`requireAccess(.take)`) stays: it decides whether the optional place
  may be *written* (not through a read view or a handle, not a constant,
  a fixed binding, or a copy an `as` binds). Assignment and `!` lends use
  the same check. It does not see a temporary behind a lend (the place is
  indirect there); the fact does: such a take is `made_part`. It no
  longer sees a part of a made or branching value either.
- `payloadViewTaken` rejects `<y` of a binding a read `match` binds,
  which the fact calls a binding: stricter than the fact, never looser,
  since `y` views the subject. Named in INTERNALS.
- the consuming-receiver rule (typecheck `checkReceiverMode`): a
  receiver that copies is taken as a copy (`sema.copies`). For one that
  moves, the hint follows the fact: a binding needs `<x.m()`; a part
  needs `replace(!p.f, v).m()`, or binding a temporary to a name first.
- `cell_vec_elem` (an element of a Cell's Vec, read and written whole)
  stays in typecheck: a representation rule of the take, not a decision
  about the source.
- emit and storage read only `takes`; `takeableSubject` only builds a
  hint.
- test/run's oracle lint now forbids `moveSource`/`MoveSource`/`moveLeaves`
  in test/oracle/, which models the rule on its own.

## Soundness fixed (all also on main)

Each of these was a use of freed memory under `RIG_SANITIZE=1`:

- `w = <(a if c else b).v`, `<(o ?? a).v`, `<(get() catch a).v`,
  `<(a if c else b)[0]`: the binding still dropped the part. Now
  `branch_part`.
- `for x in <mk().v`, `<(<a).v`, `<[<a, <b][0].v`,
  `<(mk() if c else mk()).v`, `<(+a).v`, `<mk().arr` of Vecs (review C1):
  the header dropped the temporary, then the loop freed the part again.
  Now `made_part` for the `for` source too.
- `<(mk().v if c else Vec())`, `<(get() catch mk().v)`, `<mk().o?`
  (review C2): a made part as a branch leaf. Now a `made_part` leaf.

## Tests

- `test/reject/ownership/move_part_that_copies.rig` (25 errors): fields,
  elements of a Vec, array, and slice, through `?S`/`!S` and `(?s)`/`(!s)`
  lends, a `*T` handle, every carrier, a `for` source, and a generic `T`
  part.
- `move_part_of_made_value.rig` (15): owning, copying, handle, optional,
  and generic parts of made values; `for x in <` of each; made parts as
  `if`/`catch`/`?` leaves.
- `move_branch_leaves.rig` (8): copying and owning name and part leaves
  of `if`, `??`, `catch`, `?` (`<o?`, `<s.o?`).
- `move_part_of_branching_value.rig` (8): `if`, `??`, `catch`, an index,
  an optional take, a `for` source.
- `move_module_constant/` (5) and `move_declared_value.rig` (2):
  `<K`, `<geo.K`, `<KP[0]`, `<geo.KP[0]`, `<geo.mk`, `<one`,
  `<Point.origin`.
- `move_capture.rig` (8): `<` of `|+n|`, `|+p|`, `|<m|`, `|?v|`, `|!w|`,
  `|~hh|`, and `|<u|` captures, and a capture as a branch leaf.
- `move_part_of_made_value.rig` adds `<(!mk()).o`, `<gw(!mk()).o`, and
  parts through a handle made there (`<(w.upgrade()?.o)`: "reached
  through the shared handle").
- `take_through_branch_of_write_views.rig` (behavior): `<(!s if c else
  !t).o` and `<(r1 if c else r2).o` empty the place the taken leaf views.
- `move_write_view_field.rig`: `<h.w` with `w: !Int` now says "a write
  view has one holder, and `h` keeps it; lend it on with `!h.w`" (was
  "`h` would still drop it").
- `test/reject/types/consume_receiver_part.rig`: hints for owning
  receivers (`k.d.into()`, `ds[0].into()`, `mk().d.into()`).
- Behavior: `move_leaves_source_done.rig` (what still works:
  `<n`, takes, `<a if c else <b`, `<(mk() if c else <r)`, `(<o)?`,
  `<half(n)!`); `consume_receiver_copies.rig` (`s.p.into()`,
  `v[0].into()`, `p.into()`, `(+s.p).into()`, `<p.into()`, and through
  `?P` and `!P`).
- Rewritten for the rule: `move_ends_copy_value`, `take_through_lend`,
  `sigils_before_calls`, `method_consume_without_move` (now a `Text`
  field), `method_consume_through_view` (now a `Text` field). Removed:
  `copy_field_move`, `move_copies_plain_field`,
  `move_copies_plain_element`; their cases are in the reject tests.
- Corpus: the second review's 29 hand probes as
  `test/corpus/review-move-done-2-*`, with `# oracle:` verdicts (a01–a05
  left out: only the parser rejects them). The first review's 46 probes kept as
  `test/corpus/review-move-done-*`, each with `# oracle:` verdicts. p01
  is left out because only the parser rejects it. Probes t-mv1/2/4,
  audit-fuzz-pf1, audit-ownership-l07, and review-take-p109 are now
  rejected probes with `# oracle:` and `# error:` lines.

## Reference checker

`test/oracle/lower.zig` models the rule independently:

- a part that copies is C3, including one of a made value;
- an optional part of a made value is C3;
- a function, and a module's constant or a part of one, are C3;
- a branching operand (`if`/`else`, `??`, `catch`, `?`, `!`) is C3 at its
  first leaf that is not made there;
- a branch whose type is a write view is a write view, so a take through
  `(!s if c else !t)` writes the leaf's place (review 2, H1: the 126 grid
  differences and v01);
- the `for x in <e` source takes the same path.

Now listed in `test/oracle/differences`, and older than this branch:
`print((?s).n, (!s).n)` (probe p74), core-gap: whether a field copied out
of a read lend keeps the loan until the call returns. Review M3's `<mkh().n`
difference is gone: both checkers reject it.

## Docs

- CORE §5 *(built)*: "`<` always leaves its source done: a name is
  ended, an optional place is emptied to `none`, and any other place is
  rejected, a part of a value made there too, so a field or element that
  copies is copied with no `<` (`m = p.n`)."
- SPEC §7: the intro note on plain fields is replaced. Moves states the
  rule, functions and module constants, made parts, and branch leaves,
  with two `rig reject` examples (`<p.n`, `<o?`). Places: a non-optional
  field or element is neither ended nor emptied. Its claim that
  "`<(a if c else b)` and `<o?` are rejected" is now true and tested. The
  receiver table says `p.m()` takes a copy of a value that copies.
- SYNTAX: "`<p.f` takes the optional field". INTERNALS: the rule names
  `sema.moveSource`, `moveLeaves`, and who reports what. "remove the" in
  three doc examples' error text.

## Gates

- pup (19bec64d, -j 12), all green: suite 2788 passed, 0 failed, 4
  pending; corpus 6905 passed; matrix 5099 programs, 2370 ran clean,
  2729 rejected, 0 failed; `zig build test` 124/126 (2 skipped, as on
  main); oracle doc vocab 331 passed, 4 pending. Logs:
  `logs/move-done/pup3.*`.
- The second review's grid (`grid.py`, 28,815 cells: 7 types x 40
  sources x 10 wrappers x 16 carriers), rerun at 19bec64d through
  heavy.sh: **0 compiler-accepts / oracle-rejects differences** (was
  126), **3,685 / 3,685 accepted cells run sanitizer-clean**; base ->
  branch: acc->acc 3618, acc->rej 9666, rej->acc 67, rej->rej 15464. Logs:
  `logs/move-done/grid-19bec64d.{tsv,sum}`.
- Mac (heavy.sh): behavior, reject, examples, doc, classify, vocab,
  oracle (all five sets), and the review, take, audit, final-review, and
  t-mv corpus probes: 3421 passed, 0 failed, 4 pending.
  `zig build test` with a fresh cache: 125/126 (1 skipped).

## Equivalence (`test/equiv.py`, against c169ec89)

- **Over main's tree (at 19bec64d):** 9172 programs, 51 differ.
  - 12 accepted→rejected: the 11 survey programs and review-take-p109
    (`<s.a?`).
  - 2 rejected→accepted: method_consume_without_move and
    method_consume_through_view, copying receivers; both tests were
    rewritten with an owning field.
  - 37 rejected→rejected: 29 are the "drop"→"remove" wording; 8 have
    other new or changed messages, listed in the survey (one more since
    round 2: review-seam2-r2-w03 also rejects `<(!mk(1)).o`).
- **Over this branch's tree:** 9227 programs, 86 differ: the new tests
  and probes, the wording, and the M1 behavior test and probe.
  Logs: `.git/revamp/r3/logs/move-done/equiv2-*`.

## Core conformance

- **One paragraph, no exception list:** "`<` always leaves its source
  done: a name is ended, an optional place is emptied, any other source
  is rejected." Parts of made values, branch leaves, and functions are
  no longer exceptions.
- **One classifier per fact:** `sema.moveSource`, beside `handsOver`.
  The type checker and the ownership checker each act on its cases; no
  pass re-derives it.
- **Fix the class:** the class is a `<` whose source is left as it was,
  or moved while something else drops it. Every carrier and every
  branching form goes through the one fact. The review's probes are kept
  in the corpus with oracle verdicts.
