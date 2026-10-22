# Review: REVAMP-3 steps 4 and 5 (`r3-step45` at `3098df0f`)

Independent reviewer; I wrote none of this code. I used the worktree's
`bin/rig` and `bin/rig-oracle` (built at `3098df0f`) and compared with
`rig-45-base`. Every probe ran with `RIG_SANITIZE=1 bin/rig run`. I ran
no suites and changed nothing in the worktree. I stopped all runs during
the lead's two PAUSE windows.

Probes are in `.git/revamp/r3/probes/review-step45/`, one file per
probe, each with a header comment. `HEAD-results.txt` there holds every
probe's verdict at HEAD; `run.sh` runs a probe on the new binary, the
base binary and the oracle.

## Verdict

Most of the new surface is sound in my probes:

- **Element places on a named container.** `?v[i]`, `!v[i]` and
  `<v[i]` of `T?`; `v[i] = x` drops the old value once, including when
  `x` reads `v`, `x` grows `v`, `x` fails, or the index has side
  effects. Copying an owner out of an element is rejected in every form
  I tried. Push, insert, remove, clear, swap and take while an element
  is lent are all rejected.
- **Vec of views.** The loans hold through push, insert, element
  assignment, nested `!m[0].push`, methods, generic push, moves into
  structs and Vecs, pop, remove, take, `+v`, and stores through held
  write views (the `absorbLoans` path).
- **ArrayIntoIter.** Break, continue, early return, `!` errors, `-x`,
  nesting, indexed loops, arrays of Vecs, Boxes, optionals, Cell
  holders, and made arrays: no leaks, no double drops, right drop order.
- **Deep clone.** Recursive Box lists, Vec of `*D` and `~D` (counts are
  right: one drop, after the last handle), arrays and optionals of
  owners, generic struct instances, structs holding pointer views.
  Clone of a Cell, a unique type or a drop body nested anywhere is
  rejected.
- **Re-pointing a local** (`w = !n`, `w = <w2`, `w = f(!v)`, branching
  right sides, `![]T` locals). It is sound; it is only more conservative
  than the plan in some cases (M1, M2).
- **The removed failing-tail-block exits.** These are really
  unreachable: every tail-error form I tried (match arm, if-value,
  block, `catch` handler, rethrow) is rejected with the
  "only as the operand of `return`" error or a type error, on the base
  too. `return (Bad.oops if c else <v)` and `return match …` with
  defer and errdefer run correctly.

I found three soundness holes. All three are where element places meet
older machinery:

| # | Sev | New? | Finding |
|---|---|---|---|
| C1 | **Critical** | memory corruption is new; the wrong-result form is in the base | A header subject that is an element place whose index makes a temporary (`match !v[idx(?Text("a"))]`, `if !v[…] as t`, `while !v[…] as t`, and a field of such an element) binds a **copy** of the element. Writes through the binding grow the copy's buffer and free the original's: use of freed memory. |
| H1 | **High** | the wrong-result and internal-error forms are in the base for arrays; Vec reach is new | The same copy, with read subjects. A Cell change through a guarded `match v[idx(…)]` is lost (r12). `if v[idx(…)] as c` over a Cell holder is an emit internal error (r11). |
| H2 | **High** | new | A Cell change through an element of a read-viewed Vec (`v: ?Vec[C]`, `v[0].c.set(…)`; `?Vec[Cell[Int]]`, `v[0].set(…)`) emits `.slot()` on a `*const Vec`. The Zig does not compile. |
| H3 | **High** | new | A generic loop `for x in v` over `?Vec[T]` copies each element with no per-instance requirement. With `T` a Cell holder (unique), the change is lost. The array and slice branches require `no_move` and `no_cell`; the Vec branch does not. |
| M1 | Medium | | A re-pointed **field** still keeps its old loan. `n39` (`h.w = !n; m = 10`) is still rejected, but plan 4.4 says it is fixed. |
| M2 | Medium | | Re-pointing in a loop, or back to the place the view already holds (`w = !b` while `w` may view `b`), is rejected: "cannot take a second write borrow". The old view is dead (it is overwritten and never read), so Core sentence 6 allows it. |
| M3 | Medium | | Plan items not built: 4.6 (`std/slices` and `std/sort` search still take `x: T`, so `slices.contains(?v, …)` on `Vec[Text]` is rejected) and 5.4 (CORE still lists a bare `break x` and a block's last value as *planned*). A generic `for e in xs` over `[]T` rejects `T = Text`, while the same loop over `?Vec[T]` accepts it (see H3). |
| L1 | Low | | Diagnostics. An array of owners copied bare says "bare use of \`value\` value \`a\` … \`value\` carries drop glue" (f02, p07). `+s` on a struct holding a unique type gives the drop/Cell/Signal/write-view reason (i17). `+v` of a `Vec[T]` in a generic body gives the same reason (i18), where the real reason is that a type parameter has no deep clone. |
| L2 | Low | no (base) | `defer !v.push(2)` followed by a read view used before the scope ends is rejected (k04b, base too). The oracle accepts it: `stricter`. |
| L3 | Low | | Oracle gap: a view of an inner-scope value pushed into an outer struct's Vec field is accepted by the oracle and rightly rejected by the compiler (b05, `stricter`). |

**Is the new surface sound as a whole?** No, not yet: C1 is memory
corruption in an accepted program. But the holes do not come from the
step 4 design. Each is a place where emit, or a checker branch, still
treats an element as a value:

- C1 and H1: emit's header block yields the subject's value, not its
  place;
- H2: the Cell-place path uses the mutable slot accessor;
- H3: the Vec loop branch skips `readElement`.

The element-place rules themselves (`ownership.zig` `movePath`, the drop
in `emitPlaceAssign`, the Vec loans) held up under every probe.

**What should stop.** C1 and H1 belong to the class of step 3's R2-C1:
a header subject with header temporaries is matched as a copy while the
checker records a view. Step 3's second round already stopped escaping
payload views over that class. Under the rule "a second soundness round
stops the feature", these are a further round of the same class, now
reaching write subjects and `if … as` and `while … as`. My
recommendation:

- Do not patch the copy path case by case. In sema, reject a header
  subject that is a place reached through a header temporary: an index
  or call argument in the subject's path that makes a temporary. The
  diagnostic should say to bind the index first. This holds until
  step 10's lowering.
- Or, as one class fix, have emit evaluate the subject's indices into
  `__rig_ix` constants before the header block, as `openAssign` already
  does for assignments, and break with the place's address.

H2 and H3 are first-round findings in step 4 and can be fixed in place.
None of step 4's or step 5's own features needs to stop.

---

## C1 (Critical): a write header subject on an element with a header temporary binds a copy

**Repro** (`r15_match_write_elem_header_temp.rig`):

```rig
enum E
  a(t: Text)
  b(n: Int)

fun idx(s: String) -> Int
  s.len - 1

sub main
  v: Vec[E] = Vec()
  !v.push(E.a(t: Text("hi")))
  match !v[idx(?Text("a"))]
    .a(t) if t.len > 0
      for _ in 0..40
        !t.add("xxxxxxxx")
    .a(t)
      !t.add("?")
    .b(n)
      print(n)
  match v[0]
    .a(t) => print(t.len)
    .b(n) => print(n)
```

Output: `2`, then `error: rig: use of freed memory at address …` (in
`ArrayList.deinit`, exit 134). The original keeps length 2, and its
buffer has been freed by the copy's realloc.

**Emit** (`rig emit`):

```zig
var __rig_subject_2: E = (__rig_hdr_3: { var __rig_tmp_4: rig.Text = undefined; …
    break :__rig_hdr_3 v.constSlot(idx(rig.keep(&__rig_tmp_4, …).*.bytes())).*; });
…
const t = &__rig_subject_2.a.t;   // a view of the copy
```

**Siblings, all accepted:**

- `r19_ifas_write_elem_header_temp.rig`: `if !v[idx(?Text("a"))] as t`,
  then grow `t`. Prints `1` (the write is lost), then use of freed
  memory.
- `r24_match_write_elem_field_header_temp.rig`:
  `match !v[idx(…)].e`, a field of the element. Use of freed memory.
- `r25_while_write_elem_header_temp.rig`: `while !v[idx(…)] as t`. Use
  of freed memory.
- `r15b_match_write_elem_temp_noguard.rig`: the unguarded form. The
  subject is an rvalue, so the Zig does not compile: `expected type
  '*rig.runtime.Text', found '*const rig.runtime.Text'`.
- Unaffected, and correct:
  - `r18`, `for t in !m[idx(…)]`;
  - `r20`, `if <v[idx(…)] as t`;
  - `r21` and `r22`, read loops and unguarded read matches on owners;
  - `r23`, every statement form with a temporary in an index
    (assignment, compound assignment, receiver, argument, `<`, `?`).

**New or not.** The base rejects `Vec[E]` of owners, so the memory
corruption is new in `eebbde9c`. The class is older. The base accepts
the plain-data forms and loses the write:

- `r17_match_write_arr_elem_header_temp.rig` prints `[.a(n: 1)]` on both
  binaries, where `[.a(n: 50)]` is expected;
- `r19b_ifas_write_arr_elem_header_temp_plain.rig` prints `[1]` on
  both, where `[50]` is expected.

The oracle accepts all of these (`prod=accept ref=accept`): it does not
see emit's copy.

**Root cause.** `src/emit.zig` `openHeader`/`emitHeader` (around line
1113) wraps a header that has temporaries in
`(__rig_hdr_N: { temps; break :__rig_hdr_N <emitBare(e)>; })`. For a
place subject this breaks with the element's **value**. A guarded match
then copies it into `var __rig_subject_N` (`evalSubject`, around
line 2451). The ownership checker binds the payload or binding as a view
of `v`, with the loan on `v`. This is the class "the checker checks
exactly what is emitted", the same as step 3's R2-C1.

**Fix (class).** Either:

- reject in sema a header subject whose place path evaluates a
  temporary (the simplest way to keep accept-means-correct); or
- evaluate the path's indices into constants before the header block,
  as `openAssign` and `hoistIndices` do for assignments, and reach the
  place after the temporaries end. The indices are plain values, so a
  slot pointer stays valid.

Tests: r15, r19, r24 and r25 as behavior tests (or reject tests, if
sema rejects), plus r17 and r19b for the plain-data meaning.

## H1 (High): the same copy with read subjects, for Cell holders

- `r12_match_elem_header_temp_cell.rig`: a guarded `match
  v[idx(?Text("a"))]` over `Vec[E]` holding `C { c: Cell[Int] }`; the
  arm does `x.c.set(5)`. It prints `1`, where `5` is expected (the Cell
  change landed in `__rig_subject_2`). This is new reach: the base
  rejects `Vec[E]`. The array form `r16` prints `1` on the base too.
- `r11_ifas_elem_header_temp_cell.rig`: `if v[idx(?Text("a"))] as c`
  over `Vec[C?]`. `rig check` accepts, then emit fails: `internal error:
  cannot emit a temporary outside a statement (sema should have
  rejected it)`. The array form `r11b` fails the same way on the base:
  pre-existing.

Root cause: as for C1. These are HANDOFF's "Copies of a type holding a
`Cell`" weak spot, now reachable through Vec elements.

## H2 (High): a Cell change through an element of a read-viewed Vec does not compile in Zig

`r02a_readview_vec_cell_elem.rig`:

```rig
struct C
  c: Cell[Int]

sub bump(v: ?Vec[C])
  v[0].c.set(30)
```

`rig check` accepts it. The Zig fails:
`@constCast(&v.*.slot(0).*.c).set(30)`, `expected type '*T', found
'*const T'` (`Vec.slot` takes `*Self`). `r02e` (`v: ?Vec[Cell[Int]]`,
`v[0].set(30)`) fails the same way.

These work:

- a local `r = ?v` (`r02c`), because the pointer there is not const;
- arrays and slices (`r02b`, through `rig.elemPtr`);
- a `?self` method on the element (`r14`);
- `?Box[S]` (`r02f`).

This is new: the base rejects these Vecs.

Root cause: `emitCellPtr` calls `emitAddressOf(...)`, which reaches
`emitIndex` with `as_place` true and `read_place` false. So it writes
`.slot(` (`src/emit.zig` around line 3910:
`if (self.read_place or !as_place) ".constSlot(" else ".slot("`). A Cell
place under a read view needs `constSlot` inside the `@constCast`. Class:
the Cell place reached through a const view. Check the sibling paths
(field-then-index, index-then-index, `?self` on `v[i].f`) with the fix.

## H3 (High): a generic loop over `?Vec[T]` copies elements with no per-instance check

`c11_generic_elem_in_place_cell.rig`:

```rig
sub each[T](v: ?Vec[T], f: ?sub(?T))
  for x in v
    f(x)
```

With `T = C` (a Cell holder) and `|x| x.hit()`, it prints `1`, where
`2` is expected. The emit is `for (v.*.items()) |x| { f.call(.{ &x }); }`,
a by-value capture. The array form (`c11b`) is rejected on both
binaries: "copies into a loop binding a value that holds a `T`, and `C`
is unique". The Vec form is new, since the base rejected `Vec[C]`.

Root cause: in `typecheck.elementTypeForLoop`, the `Vec` branch returns
`elem` when `sema.moves(elem) != .yes`. For a type parameter that is
`.depends`, so no requirement is added. The array and slice branches
call `readElement`, which requires `no_move` and `no_cell` of each
instance. So also:

- c07 (`T = Text` over `?Vec[T]`) is accepted, while the same loop over
  `[]T` (`std.slices.index_of`, r07) is rejected;
- a `unique` type such as `Random` is silently duplicated per
  iteration.

Fix: the Vec branch uses `readElement` for every element that is not a
resource.

## M1: a re-pointed field keeps the old loan (n39)

The corpus probe `test/corpus/r3-s36-n39_field_repoint_then_old_owner_write.rig`
and `h04_field_repoint.rig` (`h.w = !b; a = Text("A")`) are both still
rejected: "cannot reassign `a` while borrows are live". Plan 4.4
(audit-steps3-6 line 268) says `walkFieldAssign` replaces the field's
loans. The commit only re-points locals.

## M2: re-pointing in a loop or to the same place is rejected

- `g10_repoint_loop_while_view_live.rig`: `w = !b` / `w = !a`,
  alternating in a loop;
- `g05_repoint_loop_elems.rig`: `w = !v[i]` in a loop;
- `s04_repoint_annotated.rig`: `w = match k … => !a`, while `w` views
  `a`.

All three report "cannot take a second write borrow". The right side is
lent before the old value of `w` is discarded. Its old view has no
further use, so by Core sentence 6 its loan is already over. The brief
asked for re-pointing in loops.

## M3: plan items not built

- 4.6: `std/slices.rig` `contains` and `index_of`, and `std/sort.rig`
  `lower_bound`, still take `x: T`. `slices.contains(?v, Text("b"))` on
  `Vec[Text]` is rejected through `index_of`'s generic loop (r07b).
- 5.4: CORE sentence 1 still lists "a block's last value and `break x`"
  as *planned*. `break <t` works (k14).

Neither is a soundness issue. The report should say whether they were
deferred.

## Low

- L1: the diagnostics above (f02, p07, i17, i18).
- L2: k04 and k04b, `defer` with a write followed by a read view
  (base behavior).
- L3: b05, an oracle gap for a view pushed into a field's Vec.

## Probe index (verdicts at HEAD in `HEAD-results.txt`)

- **a, d: element places.** View, write, take, assign while lent.
  Aliasing, drop order with side-effecting indices, a growing right
  side, a failing right side. All correct.
- **b, l, t: Vec of views.** Every loan path, including absorb through
  held write views. All rejected where they must be.
- **c: generic bodies.** All correct except c11 (H3).
- **e: ArrayIntoIter.** All clean.
- **f, p: arrays and slices of owners.** All correct. L1 diagnostics in
  f02 and p07.
- **g, h, s: re-pointing.** Sound. M1 and M2 are false rejections.
- **i: deep clone.** All correct.
- **j: Cell of containers.** Correct.
- **k: closures, defer, break, loop sources, match on elements.**
  Correct.
- **m: elements as receivers, operands and arguments; takes through
  views and handles.** Correct.
- **n: removed failing-tail exits.** Unreachable.
- **o: elements of temporaries.** Correct.
- **q: shared and Box elements.** Correct.
- **r: Cell elements and header temporaries.** C1, H1 and H2 are here.
