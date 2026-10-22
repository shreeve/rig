# The fold (text plan, step 2): one text view

Branch `fold` (worktree `../rig-fold`), from main 3ed2964f (after `Static`, #105), pushed
to origin, no PR. Head: see the end of this file (review round 1 fixes added).

## What the plan decided (and where)

`rig-questions.md`, "Text plan (DECIDED 2026-10-06, staged)": 1. `Static`; 2. **the fold
(one text view)**, after B4b; 3. the rename (Text->String, String->?String) with `^T`
and `List`. `step7/plan.md` section 2.3-2.4 (B1) and `text-rule/migration.md` section 2.1
and 3 ("F: the fold + D2/D3/D4, in today's spelling") say what the fold is:

- **D1.** A `Text`'s read view is its bytes. Today `?Text` is a pointer to the owner
  (`*const rig.Text`) and `String` is bytes; they become one type, `String`.
- **D2.** A read view of a read view is that read view (`?(?T)` is `?T`).
- **D3.** `+s` of a `String` makes a `Text` (allocates), as `+r` of a `?Vec` makes a `Vec`.
- **D4.** A place that holds a `String` is not lent to write (`swap`, `replace`, `!s`).

The record does not say, and I decided, the places listed in "Decisions to confirm".
Nothing else about the design was open.

**The rename stays mechanical.** After this branch the compiler has one text view and no
type that the rename must merge: `Text` -> `String`, `String` -> `?String`, `?Text` ->
`?String` (the one type, written either way today), `(?Text)?` / `String?` ->
`(?String)?`, `!Text` -> `!String`. The old `!String` has no image, so it is rejected
here (a type cannot be written) rather than left to the rename.

## The deciders (one each)

- **Which types are the view:** `TypeStore.absorbed` (`src/sema.zig`). `?Text`, `?String`
  and `?(?T)` intern as the view, however they are named, inferred, or instantiated. No
  pass keeps a pointer view of a Text.
- **Which bindings take a Text's bytes:** `sema.viewsTextBytes(slot, view)`: a slot that
  is a `Text` (or a write view of one) viewed as a `String`. The type checker's lend
  records the `text` row (`readViewOf`); storage plans loop elements, payloads, and `as`
  bindings by it (`loopBindsTextBytes`, `payloadByAddress`, `optionalBindsTextBytes`);
  emit reads those facts; the ownership checker gives a payload binding the `read` ref
  a view of a field has.
- **D3:** `sema.cloneable(String) = text`, and the clone's type is `Text`.
- **D4:** `synthLend` (and the capture lend) reject `!x` of a `String` place; `resolve`
  rejects `!String` as a written type.

## Desugaring (docs/INTERNALS.md, "One text view")

`?t` is `?t[..]`; `for x in ?v` over Text elements is `for e in ?v` with `x = ?e[..]`;
`.full(t)` over a Text field is `t = ?payload.t[..]`; `if o as p` over a Text (or a
`(!Text)?`) is `p = ?inner[..]`; `|?t|` is `?t[..]`; a generic `?T` at `T = Text` is
`rig.ReadView(rig.Text) = []const u8`; `+s` of a String is `Text(s)`. No new effect: the
lend, the loan, and the bytes are the ones `?t[..]` already has.

## What changed for programs

Accepted before, rejected now (D4 and its siblings): `swap(!a, !b)`, `replace(!p.f, v)`,
`replace(!v[i], ..)`, `!s`, `w = !s`, `|!s|` of a `String` place; `!String` as a type.
In the tree: 16 behavior and reject tests and 11 corpus probes rewritten (an owned `Text`
field, an assignment, a Vec of Texts, or `|?s|` for `|+s|`), each old form kept as a reject test (`reject/types/string_place_not_lent_to_write`,
`write_view_of_string_type`). Corpus: 3 more probes are now rejected
(`review-place-b4-s001/s007`, `take-t2`); they stay.

Rejected before, accepted now: `+s` of a `String` into an owned closure or a `Text` field
(`*|+s| ..`, a `Text` of its own: three probes that expected a rejection now use `|?s|`);
`show("lit")` for a `fun show(s: ?Text)`; `id[?Int](r)` (no more `??Int`);
`first[String]("b")` (corpus `stdlib-zig-lit`).

Inference: a `T` that only `?T` parameters meet a `String` for is the `Text` that `String`
views (`Bound.text_view`); a `T` another argument pins (a `Text`, or a `String`) wins, in
either order. So `get(?w, ?d)` with `w: V[Text]` still binds `T = Text`.

Removed accidental capabilities: `Box[?Text]` sliced and compared (`b[0..2]`, `b == c`)
because it held a pointer; as a `Box[String]` it does not, like `Box[String]` and
`Box[Int]` never did. Two probes (`seam3-review1-g02/g08`) use a `Box[Text]` now.

## Tests

- `behavior/types/text_view_is_string` (every binding form, generic, capture, `+s`, owned
  closure of a `+s`); `reject/types/string_place_not_lent_to_write` (6 forms),
  `write_view_of_string_type`; `cli/emit_shapes` (the emitted shape of each form and no
  `*const rig.Text`); unit tests for the type store.
- 72 corpus probes `test/corpus/fold-*` (the soundness class: a `String` that views a
  Text slot, bound by every form, with the owner changed, dropped, or returned: 45 are
  rejected by both the compiler and the oracle (listed in `oracle/rejections`), the rest
  by the compiler alone or run clean).
- The oracle models the fold (`test/oracle/lower.zig`): a binding of a Text's bytes is a
  lend of the holder; `+s` of a String carries no loan; a String read through a view
  keeps that view's loans (the `carry` rule is for slices only). Allowlist: 10 entries
  removed ("FIXED"), 2 matrix cells and 45 probes added to the rejections.

## Soundness note

The first build of the fold had one live hole, found by the corpus and the oracle before
any gate passed: a payload binding of a Text field (`match ?e / .full(t) => keep = t`)
copied the String instead of viewing the field, so the subject could be reassigned while
`t` lived (use after free under `RIG_SANITIZE=1`). `bindPayload` now gives it the `read`
ref a view of a field has. Class: bindings made by a construct, not by a written lend
(loop element, payload, `as`, capture, generic `?T`). Siblings checked: all five, each by
a probe in `fold-grid-*` (12 binders x the changes that must be rejected).

## Gates (macOS, `cpuq run --cores 2-6 --label rig:fold`, `-j "$CPUQ_CORES"`)

| Gate | Result |
|---|---|
| `./test/run` (at the head) | 3182 passed, 0 failed, 3 pending (the planned Core rules) |
| `./test/run corpus` | 10022 passed, 0 failed |
| `test/matrix.py` | 7156 programs: 3637 ran clean, 3519 rejected, 0 failed (Static: 3695 / 3461) |
| `zig build test --cache-dir "$(mktemp -d)"` | pass |
| `./test/run oracle` | 5 sets pass |
| `test/equiv.py` vs 3ed2964f | below |

The Mac had no waiters; pup was not used. Not run: Linux, `--release` grid beyond the
`# release` tests (a release needs the deep gate).

## Equivalence against 3ed2964f (same sources; 12599 programs and doc blocks)

4773 differ:

| Differs in | Programs | Why |
|---|---|---|
| `pkg` only | 4484 | `rig/runtime.zig` changed (`ReadView`, `lend`, `viewed`, `viewedPtr` for a `Text`). Verified: in 4502 kept package pairs the only file that differs is `rig/runtime.zig`; the other 169 add `__rig_main.zig` (and 2 an imported module). `emit`, `sema`, and `storage` are identical |
| `sema` + `pkg` | 18 | a type prints `String` where it printed `?String` (D2); emit identical |
| `sema` + `emit` + `pkg` (+ `storage`) | 169 | below |
| `check` + `facts` | 102 | diagnostics and facts that print types: 94 rejected both ways (text or fact lines differ), 2 reject->accept, 6 accept->reject (below) |

The 169 emit differences, by class (clusters of changed lines; every one is a `?Text`
site becoming the Text's bytes, or the type that follows from it):

1. A pointer view of a Text becomes `.bytes()`: parameters and results `*const rig.Text`
   -> `[]const u8`; `const v = &t;` -> `const v: []const u8 = t.bytes();`; arguments
   `f(&t)` -> `f(t.bytes())`; fields; `Vec(*const rig.Text)` -> `Vec([]const u8)`.
2. Bindings of a slot: loop `|*x|` -> `|*__rig_elem_N|` + `const x = __rig_elem_N.bytes();`;
   payload `const t = &__rig_payload.t;` -> `.bytes()`; `as` bindings; captures
   `.cap_t = t.bytes()`.
3. Uses of such a value: `p.*.length()` -> `rig.len(p.len)`, `p.*.bytes()` -> `p`,
   `@as([]const u8, ..)` around branch leaves (a String branch is one slice type).
4. Generic instances: `ReadView(rig.Text)` is `[]const u8`; `id(&t, &u)` ->
   `id(t.bytes(), u.bytes())`; a `T` bound only by `?T` meeting a String is `rig.Text`
   (`first(rig.Text, ..)` where it was `[]const u8`).
5. `+s` of a String: `s` -> `rig.Text.of(.{ s })` (`rig.cloneValue(&(s.*))` for a capture).
6. `const x = ..` -> `const x: []const u8 = ..` where a binding's type is now the String.

Checks that these are all and only that: **no emitted program names `*const rig.Text`
(old: 93 programs; new: 0)**; **the 168 emit-differing programs (the 169th is a doc block
the doc tests run) print the same stdout and exit status under both compilers with
`RIG_SANITIZE=1`**.

Status flips among all programs:

- reject->accept (2): the new behavior test; `corpus/stdlib-zig-lit` (`first[String]("b")`,
  `?K` with `K = String` is the String, D2).
- accept->reject (6): `review-place-b4-s001`, `-s007`, `take-t2` (D4); `write_view_of_string_type`
  (new test); `seam3-review1-g02/g08` (a `Box[?Text]` sliced and compared, now a
  `Box[String]`; the probes were rewritten to `Box[Text]`, which both compilers run alike).

## Decisions to confirm

1. **CORE text (not edited).** Proposed, for section 4, after the table (the `Text` row
   stays: it is the `text` row, the one place a lend turns an owner into bytes):

   > A `Text` lends a `String`, its bytes, and that is its only read view: `?t`, a loop
   > or pattern binding of a `Text`, and a generic `?T` at `T = Text` are all `String`s.
   > A read view of a read view is that read view. A `String` is a view, so nothing
   > lends a `String` place to write; assign to it to point it at other text, or hold a
   > `Text`. *(built)*

   Add the table row `| a held read view | itself | nothing | built |` (it already
   describes `?r` of a `?Vec` and `?s` of a `String`). In section 2, sentence 2 gains
   "`+s` of a `String` is a new `Text`" under "`+x` makes a new owner". Section 1's
   `view` rows keep `String`; after the rename they read `?String`.
2. **D2 is `?(?T)` = `?T` only.** The semantics report also asked for `?([]T)` = `[]T`
   (today `?[]Int` is a separate type); not needed by the fold, not done.
3. **Inference rule.** `?T` meeting a `String` binds the `Text` it views unless another
   argument pins `T`. The alternative (`T = String`, the view) makes the oracle abstain
   ("a generic instance at a view") and differs from today's `?d` of a `Text` (`T = Text`).
4. **`!String` is rejected as a written type** (only `String`; `!?Int` stays a legal,
   unsatisfiable type: `!(?T)` of a Cell holder is meaningful, `corpus/review-cell-temp2-p15`).
5. **Accidental capabilities of `Box[?Text]` are gone** (slice, `==`); see above.
6. **The oracle's `.string` carry rule is removed** (a String read through a view keeps
   the view's loans). This makes the oracle stricter for Strings and loses no verdict
   in any set; it closes the gap in which it accepted `s = name(?p)[1..]` for a
   `-> String` function (an accepted-by-oracle, rejected-by-compiler pair that existed).

## Left for the rename (all mechanical now)

`Text` -> `String`; `String` -> `?String`; `(?String)?` before a suffix; `!Text` ->
`!String`; the rewritten tests keep their meaning; messages that print `String` for the
view print `?String`. Runtime names (`rig.Text`) and compiler tags are step B4.

## Review round 1 (review-fold-1.md): two High findings, fixed

**H1, evaluation order of arguments (UAF).** `show(n: grow(!t), s: ?t)` was checked in
written order but emitted in declaration order, so a view held by value (`t.bytes()`, a slice,
a copy of a number) was taken before the write. Class: the order a call evaluates its
arguments in (also on main, for a `String` parameter and for numbers). Rule, now in INTERNALS
("Evaluation order of arguments"): arguments are evaluated as written, passed as declared. The
one decider is `isPureArg`: a `?x`/`!x` of a name is left in place only when it is a pointer
view with no lend rows (or the name is fixed); any by-value view is impure, so a reorder
against another impure argument hoists both into temporaries in written order, as the existing
hoisting already did for calls. Siblings checked: methods, generic calls, constructors
(already in written order), default arguments, element places (never pure). Tests:
`behavior/emit/named_args_source_order` (fails before, 6 forms, sanitizer, release), matrix family
`named.<call>.<kind>.<order>` (fun/method/generic x String/?Text/slice/Int x declared/swapped;
9 cells failed before the fix, 0 after), corpus `fold-order-i01*`. Emit changes in 13 existing
programs vs main (extra `__rig_arg` temporaries where a `!v` slice lend is in a call that is
already hoisted); all run alike.

**H2, oracle lost 5 rejections.** `optionalInner` did not see through the subject's read view,
so `if/while ?p as x` over a `Text?` lost its loan in the oracle. One-line fix
(`unwrapViews`). Tests: 7 `fold-oracle-*` probes (the reviewer's 6 siblings and one more) plus
the 5 lost ones, all listed in `oracle/rejections` (11 entries).

Gates at the new head: suite 3183 (+1 oracle-list fix, rerun green), corpus 10032/10032, matrix
7174 programs (3649 clean, 3525 rejected, 0 failed), unit pass, oracle 5 sets pass, equiv 12610
programs / 4777 differ (the earlier classes, plus the 13 programs above).
