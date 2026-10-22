# Review: REVAMP-3 step 1, "Type facts" (`485e1a06..r3-step1` = `b7ca0e90`)

Reviewer: independent; wrote none of this code. Compiler built from
`git archive b7ca0e90` in a scratch copy; base for comparison is
`.git/revamp/r3/rig-485e`. Every probe was run with `RIG_SANITIZE=1
bin/rig run`. Probes are saved in `.git/revamp/r3/probes/review-step1/`
(`run.sh` runs new and, with `CMP=1`, base; edit `NEW=` to point at a
build of `r3-step1`).

## Summary

The facts layer itself is sound and well placed: `moves`, `copyable`,
`cloneable`, `isUnique`, `lendByValue`, `readsAsValue` in `sema.zig` are
correct, the receiver reservation keeps its exact set under `isScalar`
(F2 handled), `Requirement.plain` is split, and `struct T unique` parses
as a contextual keyword with no collateral (field, method, local and type
named `unique` all work). Bare copies of a Cell-holder or a declared-unique
value are now rejected through every non-generic path I tried: binding,
argument, field init and assignment, `h.c`, `r.c` through a view,
`return h.c`, `arr`, `arr[i]`, `s[i]` of a slice, `a.get(i)`, `fill`,
`[n of x]`, `??`, ternary, `match`/`if` value blocks, `catch d`, `o?`,
`if o as c` / `while o as c` on a place, `Wrap[Counter]`, `E` with a
Counter payload, generic `T` copies (`y = x`, `[x, y]`, `a[0]`,
`return k` from a generic loop), `|+a|`, `+a`, `+c`, `Cell.get`. `*Counter`
still clones as a count; `Cell[Counter]`, `Cell[Cell[Int]]` set/replace
work leak-free; Rng's owned bindings (`if !o as q`, `if <o as q`, `match
<e`, `Box`, `*Rng`, `Cell[Rng].replace`) emit compiling Zig; plain
payload copies stay correct while the scrutinee is reassigned (debug and
release).

The problems are in the new **view** paths (1.5) and in what the step
claims as built:

| # | Sev | Finding |
|---|---|---|
| C1 | **Critical** | A loop that views Cell-holder elements of an array **literal** (or a field of a struct literal, or a literal passed as a `[]T`) writes through `@constCast` into read-only memory: `Bus error` under the sanitizer. New in `8e84548b`. |
| C2 | **High** (soundness) | A loop over a **made value** (`for k in two()`) binds `k` as a view of a temporary with no loan: `saved = k` used after the loop is accepted; the emitted Zig keeps a pointer to an expired temporary. New in `8e84548b`. |
| H1 | High | Cell-holders are still copied (state forked) through generic bodies (`rig.borrowed` copies the aggregate; generic loop elements and read payloads bind by value) and through a slice element receiver (`s[0].hit()` via `rig.at`). Pre-existing, but CORE §1 now marks "a type that holds a Cell is unique" *(built)*. |
| M1 | Medium | `keptLikeOwner` (= cleanup ∨ declared `unique`) is a new proxy that splits "unique" in two: `[2]Rng` is rejected with "arrays cannot hold unique values" while `[2]Counter` is accepted; a discarded `Rng` is rejected, a discarded `Counter` is accepted; `print(r, step(!r))` is rejected for Rng, accepted for Counter. CORE §1 does not distinguish them; SPEC's new paragraph states the split as an exception list. |
| M2 | Medium | Lifting a pointer view `?T` into `(?T)?` emits `k.*` and the Zig does not compile. Pre-existing for named views, now reachable from every Cell-holder loop element and read payload. |
| M3 | Medium | SPEC §10 says a by-value parameter cannot be changed or lent to something that could change it; the suite now tests the opposite (`c.hit()` on `c: Counter`), while `c.hits.set` stays rejected. Three diagnostics still call owned or viewed bindings "a loop or match binding, a copy". |
| L1–L7 | Low | Requirement named `copyable` checks `moves`; lost reject coverage of "elements cannot be moved out of their container"; a garbled INTERNALS sentence; CORE §9 status; emitted no-op drops the checker does not model; stale loop-step message; no Cell-holder or unique row in `test/matrix.py`. |

No weakened test hides a regression, no comment narrates history, and I
found no Zig 0.17 API misuse in the diff (packed-struct `@bitCast`,
`std.ArrayList(...) = .empty`, `@constCast` are used as the rest of the
emitter uses them).

---

## C1 (Critical): in-place loop views write into read-only literal memory

**Where:** `src/typecheck.zig:1788` and `:1802` (`elementTypeForLoop`
makes a Cell-holder element `?elem` for any source); `src/emit.zig:2129-2137`
(`emitFor`: `by_ptr` + `array_ptr` emit `for (&SOURCE) |*k|`); method and
`set` calls on the view emit `@constCast(&k.hits).set(...)`.

**Repro** (`p17e_for_literal.rig`, also `p17f`, `p42_lit_variants.rig`,
`p42c.rig`, `p47_slice_lit.rig`):

```rig
struct Counter
  hits: Cell[Int]

  sub hit(?self)
    self.hits.set(self.hits.get() + 1)

sub main()
  for k in [Counter(hits: Cell(0)), Counter(hits: Cell(5))]
    k.hit()
    print(k.hits.get())
```

`rig check` accepts it; `RIG_SANITIZE=1 rig run` dies with `Bus error at
address ...` in `Cell.set` (runtime.zig:556). Emitted:

```zig
for (&[_]Counter{ Counter{ .hits = rig.Cell(i64){ .value = 0 } }, ... }) |*k| {
    @constCast(&k.hits).set(k.hits.get() + 1);
```

The comptime-known array literal lives in rodata. The same crash for
`for k in H(arr: [...]).arr`, `for k, i in [...]`, and
`sub bump(s: []Counter) for k in s: k.hit()` called as
`bump([Counter(hits: Cell(0))])`. Base rejected all of these (the loop
binding was a copy). The audit listed exactly this risk (§7.4).

**Sibling, pre-existing:** `fun look(s: []Counter) bumpc(?s[0])` called
as `look([Counter(...)])` (`p47e.rig`) crashes the same way on base. The
class is "a value holding a Cell placed in comptime constant memory and
then lent"; the existing rule "cannot borrow a temporary that holds a
Cell" (`?mk()`, `?(E.a(...))`) is not applied to an array literal used
as a loop source or implicitly lent to a `[]T`/`?[N]T` parameter.

**Fix (class):** one rule for "a made value holding a Cell is lent":
either (a) typecheck rejects it everywhere with the existing diagnostic
(loop source that is a made value whose element holds a Cell and is
viewed; an array literal coerced to `[]T` whose element holds a Cell), or
(b) emit always materializes such a made value into a `var` local before
taking its address (`var __rig_src = two(); for (&__rig_src) |*k|`), and
the checker gives that hidden var the loop's scope (see C2). (b) keeps
the new acceptances; (a) is smaller. Add reject or behavior tests for
each of the five shapes above, plus `p47e`.

## C2 (High, soundness): a loop view of a taken temporary escapes the loop

**Where:** `src/ownership.zig:3918-3935` (`bindLoopElems`): elements get
a loan only when `spec.source_root` is a live var; a made-value source
has none, so a `?Counter` element carries no loan at all.
`src/typecheck.zig:1788` makes the element a view regardless of whether
the source is a place.

**Repro** (`p32b_temp_store.rig`, `p32d_dangle.rig`):

```rig
struct Counter
  hits: Cell[Int]

fun two(n: Int) -> [2]Counter
  [Counter(hits: Cell(n)), Counter(hits: Cell(n + 1))]

sub main()
  one = [Counter(hits: Cell(1))]
  saved = ?one[0]
  for k in two(10)
    saved = k
  print(saved.hits.get())
```

Accepted; emitted:

```zig
var saved: *const Counter = &one[0];
for (&two(10)) |*k| { saved = k; }
rig.print(.{ saved.hits.get() });
```

`saved` points into the `for` statement's temporary after it has ended
(it prints `11` today only because the stack slot is not reused). Core
§3: the temporary a `for` takes lives through the body, not after it.
`@constCast` writes into that `const` temporary are also illegal in Zig
even when they happen to work (`p17i_for_call.rig`). Base rejected
`saved = k` (type mismatch: `k` was a value).

**Fix:** for a made-value source, either bind elements by value (the
array is taken, so each element moves out once; no view is needed and
the Cell cannot fork because the array is gone), or add a hidden var for
the taken source scoped to the loop body and give the element view a
loan on it, so `saved = k` reports "a borrow of the temporary ... outlives
its statement". Emit must then store the source in a `var` (C1 fix b).
Add `p32b` as a reject test.

## H1 (High): Cell-holders are still forked through generics and slice receivers

CORE.md §1 now says *(built)*: "A type that holds a `Cell`, or a bare
`Cell[T]`, is unique too, because a copy would fork state". Bare copies
are rejected, but these accepted programs still copy a Cell-holder and
lose a change (all print `0` where the Core meaning is `1`/`2`; base
behaves the same):

| Probe | Shape | Emitted copy |
|---|---|---|
| `p38c_generic_ptr.rig` | `sub each[T](xs: ?[2]T, f: ?fun(?T) -> Int)  _ = f(?xs[0])` with `T = Counter`, `f` calls `hit` | `rig.lend(&rig.borrowed([2]T, xs)[0])`: `rig.borrowed` (runtime.zig:108-110) returns `borrow.*`, a copy of the whole array |
| `p38_generic_each.rig` | generic `for k in xs: f(?k)` | `for (rig.borrowed([2]T, xs)) \|k\|` by value |
| `p38b_generic_match.rig` | generic `match o .some(v) => f(?v)` on `?Opt[T]` | `switch (rig.borrowed(Opt(T), o))` + `const v = payload.v` |
| `p47c.rig` | `sub bump(s: []Counter)  s[0].hit()` | `rig.at(s, 0).hit()` (emit.zig:3643): `rig.at` returns the element by value |

None is memory-unsafe, but each is the "wrong-meaning acceptance" F3/F16
were meant to remove, and the step's own rule (1.5) is "a Cell-holder is
viewed, not copied, by loops and matches", which the generic instance does
not follow because `holdsCellByValue(T)` is false in the body.

**Fix:** (1) a generic `?T` index or field path indexes through the
pointer instead of dereferencing the aggregate (`rig.borrowed` is only
needed for the final read of a whole `T`; `xs[0]` is valid Zig on a
`*const [2]T`); (2) generic loop elements and read-mode payloads whose
type holds a type parameter bind as `rig.ReadBorrow(T)` (pointer when the
instance holds a Cell, value otherwise, the rule `ReadBorrow` already
applies); (3) a method call whose receiver is a slice or array element
holding a Cell (or of a type parameter) takes `rig.elemPtr`, as
`?s[0]` already does. Until then, CORE §1 bullet 2 should not say
*(built)* without qualification.

## M1 (Medium): `keptLikeOwner` splits "unique" into two kinds

**Where:** `src/sema.zig:3417-3428` (`readByAddress`, `keptLikeOwner`),
used at resolve.zig:648-670 (arrays, slices), typecheck.zig:649 (discard),
917 (element overwrite), 1609 (loop over temporary), 2943 (none test),
2977 (`==` read), 3447, 3633, 3683, 3690, 4455, 4570 (temporaries, array
literal, slice), sema.zig:1735 (unused lint), ownership.zig:1179, 2592,
4143, and through `readByAddress` ownership.zig:2973, 3007, emit.zig:4915.

`keptLikeOwner = glue ∨ declared unique`, and a Cell-holder is unique but
not "kept like an owner". The rules this produces do not follow from CORE
§1, which names both as unique and says nothing about arrays or discards
for either:

| Program | `Rng` (declared) | `Counter` (holds a Cell) |
|---|---|---|
| `[2]T` array | rejected: "arrays cannot hold unique values" | accepted (and viewed in loops) |
| discarded statement | rejected: "is unique and would be lost" | `mk()` accepted |
| `print(x, step(!x))` | rejected (read by address) | accepted (copied into the print tuple) |

The array diagnostic is false as written (Counter is unique and allowed).
SPEC.md:704-711 states the split as a rule ("Arrays, slices, `==`, and a
discarded statement reject a value of a type declared `unique`"), which
is the exception list AGENTS.md "How we build" forbids. CORE §5 says
arrays hold any kind, needing copyable elements only for `copy`, `fill`,
`[n of x]`, and every copy-out path already uses `moves` (`cannotCopy`),
so the audit's A2/A3 (admit `[N]Rng`, accept a discarded Rng) are the
rule the Core implies; they are wrong rejections removed, which the
feature freeze allows.

**Fix:** make `keptLikeOwner` exactly `typeHasDropGlue` (then delete it
and call the cleanup fact by name), drop the "unique" branches of the
array/slice/discard/temporary diagnostics, keep `==` refused for a
declared-unique type through `EquatableWalk` (`.unique`, already added),
and update SPEC.md:704-711 and `rng_unique_kept_out.rig`. If the design
owner wants to keep the Rng limits, CORE §1 must say so in one sentence
that also covers Cell-holders, and the diagnostic must not claim a rule
the compiler does not apply.

## M2 (Medium, pre-existing, newly reachable): `?T` lifted into `(?T)?` emits a deref

**Repro** (`p33c_arr_opt_view.rig`, `p34b_opt_view_param.rig`,
`p34c_match_view_opt.rig`; base sibling `p34_opt_view.rig`,
`p34d_plain.rig`):

```rig
fun show(o: (?Counter)?) -> Int
  if o as s
    return s.hits.get()
  0

sub main()
  a = [Counter(hits: Cell(0)), Counter(hits: Cell(5))]
  for k in a
    print(show(k))
```

`rig check` accepts; the emitted `show(k.*)` fails in Zig: "expected type
'?*const Counter', found 'Counter'". Base rejected this program (`k` was
a `Counter`), but `r = ?p; saved: (?P)? = none; saved = r` fails the
same way on base, for any pointer-represented view. Accept-means-correct
violation; the step multiplies the sites that reach it. Fix in emit's
coercion of a pointer view to an optional of that view (no `.*` when the
target is `?T`-optional of the same view), with a behavior test for a
named view, a loop element view, and a payload view.

## M3 (Medium): by-value Cell parameters: docs and diagnostics disagree with the code

- SPEC.md:3544-3548: "A by-value parameter is immutable, so it cannot be
  changed (or lent to something that could change it)." But
  `test/behavior/ownership/cell_holder_moves.rig` (`fun take(c: Counter)
  c.hit()`) and `test/behavior/runtime/cell_set_through_read_borrow.rig`
  (new comment: "a by-value parameter owns the value moved into it, which
  it may lend out") test the opposite, and `bump(?c)` on such a param is
  accepted; only `c.hits.set(5)` is rejected (`p46_param.rig`). Either
  build audit 1.7 (a `.param` root is a Cell place for a type that moves;
  `requireCellPlace`, typecheck.zig:1285) or make SPEC say what the code
  does.
- Stale wording: typecheck.zig:3338, 6394, 8086 and the `requireCellPlace`
  message still say "`c` is a loop or match binding, a copy". Since 1.5,
  a read loop or match binding of a Cell-holder is a view, and the
  binding these fire on is an *owned* one (`match <e`, a match on a call
  result, `while <o as c`: `p16d`, `p17g`, `p49_step.rig`).

## Low

- **L1** `src/typecheck.zig:8994` (`satisfies`): `.copyable =>
  sema.moves(ctx, ty) != .yes`. The requirement is named after the
  `copyable` fact but checks `moves`, so a `!T` instance satisfies
  "copies". Behavior equals base (`.plain` was `!glue`); either check
  `copyable(...) == .yes` (the view case is also covered by
  `plain_reqs.view`) or name the requirement for what it checks.
- **L2** `test/reject/ownership/move_vec_element.rig` was rewritten from
  `<v[0]` of a plain `Vec[P]` (now a copy) to a `Vec[*P]` program that
  fails in typecheck, so no test reaches ownership.zig:2210 "elements
  cannot be moved out of their container" any more. Add `k = <a[0]` with
  `a: [2]Counter` (`p35_move_elem.rig`), which hits it.
- **L3** docs/INTERNALS.md:1189-1191 reads "copy the payload (...) except
  a field that holds a Cell, which they point into as a read view, point
  into it (`|*p|` for `match !e`)": the inserted clause breaks the list.
- **L4** docs/CORE.md:671-676 (§9) still marks "Per type, one fact each"
  *(planned)*; the step builds these facts (`sema.zig:3390-3480`, INTERNALS
  "Type facts"). Mark the first bullet built, or say which fact is still
  missing ("may hold a loan" is `mayHoldBorrow`/`mayHoldView`, two
  functions).
- **L5** emit now gives every Cell-holder `var` storage, a drop guard and
  `defer rig.drop(&k)` (`kindOf` = `moves`), while ownership.zig:1179
  does not count a Cell-holder as dropped at scope exit. `rig.drop` is a
  comptime no-op here, so nothing runs, but "the checker checks exactly
  what is emitted" is true only by that accident; INTERNALS should say
  that the guard of a value without cleanup is a no-op the checker
  ignores.
- **L6** typecheck.zig:1397: the loop-step error for a unique binding says
  "it owns a `Counter`, which the body drops before the step runs"; a
  Counter owns nothing (`p49_step.rig`). Use `movesBecause`. Element
  copies report "a field cannot be moved out of its parent" for
  `arr[...]`/`s[...]`.
- **L7** `test/matrix.py` has no type that holds a Cell and no declared
  unique type. A `cell` row (`Counter`) and a `unique` row (a local
  `struct U unique`) across the existing contexts (`for_source` over a
  literal, `match_subject`, `elem_index_call`, `binding`, `arg_*`) would
  have found C1, C2 and M2; "fix the class" asks for exactly that.

## What I checked and found correct

- Facts: `moves`/`copyable`/`cloneable` unit table, `isUnique` = declared
  ∨ cell, reach through `[N]U`, `U?`, `Wrap[U]`, enum payloads, not
  through `*U`, `~U`, `Vec`, `Box`, views (`p48_slice_copy.rig`: views of
  Cell-holders copy as views).
- C1 false rejections fixed as planned: `<p` of plain payloads, `<s.p`,
  `|+p|` of plain structs, `c = w` with `w: !Color`; `a.show(bump(!a))`
  stays rejected (`isScalar`, ownership.zig:2838).
- Payload copies (`bindPayload`, ownership.zig:3699-3712) keep loans for a
  view-holding payload (`move_view_payload_keeps_loan.rig`) and read
  correctly while the scrutinee is reassigned (`p36_payload_copy.rig`,
  debug and `--release`).
- Loop/payload views over places keep the loan: reassigning the array or
  scrutinee inside the body, `<e` inside the arm, and returning a local's
  loop view are rejected (`p31*`, `p33d`); returning a param's loop view
  works (`p31d`).
- Rng: no `__rig_drop`; every owned-binding path compiles and runs
  (`p29b_rng_ok.rig`, `rng_owned_bindings.rig`); generic, optional,
  `Wrap[Rng]`, `|+r|`, `+r` rejected; `-r`, `-a`, `-c` accepted and only
  end the name; `==` refused with "is unique".
- Grammar: `unique` as struct name, field, method-free member, local,
  after `]`, with a comment, `pub struct S unique`; `struct S unique
  unique` and `struct S unique` with no body are rejected cleanly
  (`p45*`).
- Closures: `|<a|` of a Counter or `[2]Counter` (stack and owned) keeps
  one Cell; `+cb` shares the environment; `|?a| a` returns a view.
- Narrow gates in the scratch copy: `./test/run -j 2 cell_holder` and
  `rng` pass (14 programs). Full suite, corpus and matrix not rerun
  (shared machine, load 29).
