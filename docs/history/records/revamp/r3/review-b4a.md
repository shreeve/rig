# Review: B4a (branch `b4-emit` at 26f0d3ce)

Adversarial review of "emit points at a header's subject instead of
copying it". Probes are in `probes/review-b4a/`. `cmp.sh` runs a probe
under b4a and v0.2.0 with `RIG_SANITIZE=1`. `runexp.sh` checks it under
b4a, then runs it under the experiment build. Outputs are in
`probes/review-b4a/out/`. The experiment build is a copy of the worktree
in `probes/review-b4a/work/rig-exp`, with `logs/b4a/experiment.py on`
applied, plus its own `rig-oracle`.

## Verdict on the claim

The claim holds for acceptance and observable behaviour.

- **Prior probes:** every prior probe (about 1,200 runs over
  `review-step1/3/6/10/45`, `review-c-rules`, `hotfix6`, `lead-*`,
  `kinds`, `step2`, `step45`, `steps3-6`, and the `r2` sets) gives
  byte-identical sanitized output and diagnostics under b4a and v0.2.0.
- **New probes:** they cover generic payloads in every use I could
  write, such as copies, closures, `defer`, nested matches, guards,
  arrays, Box and handle subjects, branching subjects, Vec elements, and
  views a call returns. All of them match v0.2.0.
- **Header pointers:** no accepted program reaches the header-pointer
  path (`headerPoints` / `emitSubjectPtr`). `rejectHeaderCopy` still
  rejects every header with a temporary unless the value is made there,
  and a made value never "reaches a place". In B4a, the only emitted
  change for accepted programs is generic payloads bound by pointer and
  `rig.viewedPtr`. This matches the 12-program equiv diff.

## Findings (B4a as committed)

### Critical / High

None found.

### Medium: a new latent pointer into a Zig temporary, through a generic view held in a field

- **Probes:** `g20_view_field_subject.rig` and
  `g22_view_field_guard_latent.rig` (`g24` is a sibling).
- **Shape:** a guarded `match w.r`, where `w: ?V[T]` and
  `struct V[T] { r: ?Opt[T] }`.
- **Emitted code in b4a:**

  ```zig
  if (rig.viewed(Opt(T), w.r) == .some) {
      const v = &rig.viewed(Opt(T), w.r).some.v;   // address of a field of a call's rvalue
      if (look(T, rig.lend(v)) == 1) ...           // read in the next statement
  ```

  The arm repeats the same pattern: `const v = &rig.viewed(...).some.v;`,
  then several statements that use `v`.
- **v0.2.0 emitted** `const v = rig.viewed(Opt(T), w.r).some.v;`, a copy,
  which is sound.
- **Output:** correct in Debug, in `--release`, and under the sanitizer:
  `look [1..8] … 1`. It is latent: by Zig's rules this uses a temporary
  after its statement. This is design §1.7's class, newly introduced.
- **Root cause:** `storage.matchesInPlace` uses `reachesPlace`, and
  `pathHands` calls `w.r` a place. But emit writes a member that holds a
  generic read view as `rig.viewed(T, …)` (`emitExpr` `.member`/`.index`,
  emit.zig about line 3864), which is a by-value copy. The `subject_root`
  fix covers only a generic view held by the root name (`writeLocalPlace`),
  not one held by a field or element on the path.
- **Wrong fact:** the payload fact says `pointer arm`. INTERNALS says a
  payload is "never a copy in the arm", but here it is captured from a
  copy.
- **Unguarded form:** `switch (rig.viewed(Opt(T), w.r)) { .some => |*p| … }`
  is safe today because the binding is arm-local. See B4b risk 2.
- **Fix:** add a `rig.viewedPtr`-style address for any generic view on
  the subject's path, or make `matchesInPlace` false when the path
  passes through a field or element that holds a generic read view.
- **New or pre-existing:** new.

### Low: header-pointer code has no accepted user, and its classifier is wrong for one class

`headerPoints`, `emitSubjectPtr`, the `header_value pointer` facts, and
the `points` branches in `emitOptionalHead`, `emitFor`, and `evalSubject`
run only for programs that are later rejected. No suite test exercises
them as running code. That is fine for B4a, but `reachesPlace`
misclassifies the case in B4b risk 1. B4b should not inherit the rule
unchanged.

### Things checked and found sound in b4a

- **The subject changes during an arm:** reassigning it, moving it,
  pushing to the Vec it lives in, or dropping it while a generic payload
  is live is rejected. `ownership.bindPayload` gives a `depends` payload
  a loan on the root (`copies()` requires `.yes`), so the pointer binding
  matches what the checker walks. Probes: `g01`, `g02`, `g14`.
- **Mutation through other paths:** assignment through a `*T` handle is
  rejected (`h01`). Cell holders are excluded by `no_cell`.
- **`viewedPtr`:** `ReadView(X)` is a copy only for scalars, pointers,
  and optionals of them, so for every matchable payload enum
  `viewedPtr` is the view itself.
- **Leaking `subject_root`:** setting it while an index argument names
  the same root has no effect in the emitted code (`g23`).

## Risks for B4b, found under the experiment

### 1. Critical: the header points into its own temporary (a place through a view of a temporary)

- **Probes:** `x05_view_call_path_plain.rig`, `x05b_view_of_temp_forms.rig`,
  and `x05c_view_of_temp_handle.rig`.
- **Shape:**

  ```rig
  fun id(s: ?S) -> ?S from s
  match id(?mk()).e          # or (?mk()).e, for … in id(?mk()).xs,
    .a(n) => print(n)        # if/while id(?mk()).o as n
  ```

- **Why it is accepted:** `pathHands` calls a path through a view a
  place, so `headerPoints` is true. The block yields
  `&(id(&rig.keep(&tmp…)).e)`, and the `defer` then drops and poisons
  `tmp`. The bindings are plain data, so they carry no loan, and the
  ownership checker and the oracle both accept. When the payload is not
  plain data, ownership does reject it, for example
  `x01`/`x02`: "a view of the temporary `mk()` outlives its statement".
- **Output with `RIG_SANITIZE=1`, by form:**

  | Form | Output |
  |---|---|
  | `match` | `lend -6148914691236517206` (that is `0xAAAA…`) |
  | guarded `match` | `other` (wrong arm) |
  | `for` | `for -6148914691236517206` ×3 |
  | `if … as`, `while … as` | silently take the `none` path |

- **Handle variant (`x05c`):** `rig: use of freed memory`, Bus error,
  rc=134.
- **Without the sanitizer:** the correct values appear, so this is a
  silent use-after-free.
- **Root cause:** `reachesPlace` (storage.zig) accepts `.place` from
  `handsOver` without asking where the place lives. A place whose path
  starts at a view made from a header temporary (a call's result, or a
  lend `?mk()`) is storage the header block drops. B4b must treat such a
  subject as a copy and keep the rejection, or require that the place's
  root is not a header temporary. The rule could be "the base of the
  path has storage outside the header", or "the place's loans hold no
  header temporary".
- **New or pre-existing:** this is a classifier error in B4a's own rule.
  It is masked in B4a by `rejectHeaderCopy`.

### 2. High: arm-local views lifted over a generic view held in a field or element

- **Probe:** `g21_view_field_escape.rig`.
- **Shape:**

  ```rig
  fun get[T](w: ?V[T], d: ?T) -> ?T from w, d
    match w.r
      .some(v) => ?v
  ```

- **Output under the experiment:**
  `panic: programmer bug caused syscall error: INVAL` while printing the
  returned view. The view points into the dead rvalue
  `rig.viewed(Opt(T), w.r)`.
- **Oracle:** the experiment oracle flags `get` and `getg`. That is only
  because it still mirrors the arm-local rule, which the design says
  should stop.
- **Root cause:** the same as the Medium finding. B4b must not lift
  `arm_view` on the strength of `matchesInPlace` until emit reaches such
  subjects in place.

### 3. Checked and sound under the experiment

These programs either run correctly or are rejected correctly.

- **`while … as` over a pointing header:** it is evaluated again each
  pass while the body grows the Vec (its buffer moves) and writes
  through `!v[i]` (`x03`, `x16`: `a 0 / b 1 / c 2 / grown 7 / a! b! c!
  none`). A view kept across a push is rejected (`x04`).
- **Evaluation order:**
  - An index that lends the subject's Vec to write is rejected ("place
    is found up to each index before the index runs", `x12`, `x12b`).
  - An index with side effects on another Vec takes the pointer after
    them (`x13`: `a 1`, `guard b 2`).
- **Changing the subject in an arm:** reassigning or moving it under a
  pointing header is rejected (`x14`).
- **Nested matches:** an inner payload view escaping through an outer
  pointing header runs correctly (`x15`).
- **Copied subjects with arm_view off:** made subjects (`x08`, `x10`)
  bind owned payloads, which cannot escape. A held header (`x09`) and a
  view of a temporary (`x01`, `x02`) are rejected by ownership. Branching
  subjects of views point (`x11`, which runs correctly), and branching
  subjects of owned names are rejected in sema (`x06`, `x07`).
- **The agent's experiment flips:** the corpus programs that state an
  expected result match it (a07, a08, a27, a27b). The one rc=134,
  `for_source_through_temporary`, indexes an empty Vec, so it is the
  program's own bounds panic, not a soundness failure.
- **The `as` rejection over a Cell holder** (`typecheck.zig` about line
  1570) is still on in the experiment (`g20`/`g20b` from step 3 r2).
  B4b has to decide it separately.

## Oracle

- **b4a's oracle** agrees on every decided function in `g13`, `g20`,
  `g21`, and `g22`.
- **The experiment oracle** accepts `x05` and `x05b` (it abstains on
  `main` in `x05b`). It cannot see risk 1, because it judges meaning and
  not emitted storage. Only the poisoning sanitizer catches risk 1.
