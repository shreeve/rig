# PR notes: errors that carry data, round R1 (`errors`)

Design: `.git/revamp/r3/proposal-errors.md`, approved 2026-10-12 with all
18 decisions as recommended. This is §7's round R1 (`errtype`): `error`
usable as a type, `error` owning, `+e` clones it, P3 without the `full`
field, and the copied-binding rejection. R2–R4 are not here. Branch
`errors`, one commit on origin/main 54e4d16cc.

## What is built

- **`error` is a type.** The grammar's `tatom` takes the keyword `ERROR`
  (a parameter, a field, a result, `error?`, `[2]error`, `List[error]`),
  and so does `atom`, for a type argument in an expression
  (`List[error]()`, `name[error]()`, `@size(error)`). Nexus reports no
  new conflict. The lexer counts `error` as the end of an operand, so
  `error?` is its optional, not a prefix `?`. `resolveType` maps the leaf
  to `any_error`; `isBuiltinTypeName` counts it, so `x = error` is
  "`error` is a type, not a value". A member of any set meets `error`
  (`typecheck.meets`). `error!` is rejected with `E!`'s message
  (`isErrorValue` in `resolveReturnType`). `@name(T)` names it: the
  built-in names table gains `anyerror`, "error".
- **`error` is owning in every program (decision 5).** One new type fact,
  `TypeInfo.any_error` (with `Contents.any_error` and `Holds.any_error`),
  marks `error` and every type holding one inline, reaching as `vector`
  does. It is a positive input to `sema.moves` (beside glue and unique)
  and `sema.readByAddress`, read through `sema.holdsAnyError`. `error` is
  no longer `plain`. It has no glue: no set has fields yet, so there is
  nothing to release. `cloneable` gives `.deep` (no glue, not unique),
  and emit's `rig.cloneValue` copies an `anyerror`. Diagnostics:
  `kindLabel` names it "owns an `error`" (not "unique"), and
  `movesBecause` says "is owning" / "holds an `error`, which is owning".
  The catch capture's storage is recorded `owned` (it was `copy`), since
  the handler owns the failure's error; the Zig is unchanged.
- **The oracle** reads `any_error` as owning (`test/oracle/kinds.zig`),
  so the reference checker agrees.
- **Three fixes the owning kind exposed** (each found by a probe or
  the new grid row, each with a test).
  - `match <e` on an error: an arm naming one member (`A.x =>`) took the
    alternatives path and emitted `const __rig_whole = ;`. A `member`
    pattern now names its member, as `enum_lit` does.
  - Zig 0.17 rejects `_ = e` for an error value ("error set is
    discarded"). An unused parameter of an error set, `error`, a read
    view of one, or a type a generic instance gives is now discarded by
    address (`_ = &e`). This was a bug on main too: `fun f(e: A) -> Int`
    with `e` unread fails to compile there
    (`test/behavior/emit/unused_error_params.rig`).
  - `(o ?? b) == a` on errors reached emit with no recorded use for the
    branch (internal error). The `==` typing read in place only operands
    with drop glue; it now reads every operand that moves
    (`moves == .yes`), which the consume flags emit keys on. Sibling: a
    type parameter's value (`moves == .depends`) has the same internal
    error on main (`(a if c else b) == x` in a generic); it is left for
    its own task, since reading it in place adds a `no_cleanup`
    requirement to check.
- **Docs.** CORE §2 has the approved paragraph after sentence 10, split
  at sentence ends so each part is marked: fields *(planned)*; `error`
  owning *(built)*; return / `!` / the handler's own binding moved on
  with `<err` or `return err` *(built)*; the unbound `catch` drop
  *(planned)*; reading, matching, printing, storing, cloning *(built)*.
  A `rig reject` example (use after `<err`) and P1 as `rig pending`
  follow. CORE §1 lists `error` as owning and as a third kind the parts
  can't show. SPEC: `error` in the primitive table and the owning row,
  §3 Error sets, §13 "Naming the error", a new §13 "Any error" (P3
  without the field, and the copied-binding rejection), and §13
  "Declared sets and fields" with P2, full P3, P4, and the six
  rejections as `rig pending`. INTERNALS (type, storage row, lexer),
  SYNTAX, README, IDEAS 1.4, HANDOFF.

## Tests (each failed on main)

- behavior: `types/error_any_type` (param, field, result, optional,
  `List[error]`, `<e`, `+e`, `?e`, `return e`, `@name`, `List[error]()`),
  `types/error_match_move` (`match <e`: one member, alternatives, a
  whole binding, a guard), `types/error_compare_branch`,
  `emit/unused_error_params`.
- reject: `ownership/error_binding_copied` (the proposal's, with
  `error` for `E` until R2 types the binding), `error_binding_moved`
  (field-less), `error_argument_copied`, `types/fallible_any_error`,
  `types/error_is_a_type`.
- matrix: a new `error` row in the main grid (all contexts and forms but
  `catch`, since `error!` is rejected): 96 new oracle rejections listed.

## What changed for existing programs (the count)

`rig check` over every suite, corpus, and example program, base vs
branch:

- **Copies an error, now rejected: 1**, the corpus probe
  `review-errors-b3.rig` (`print([e, e], e)`). The corpus allows a
  rejection; it is listed in `test/oracle/rejections`.
- **Now accepted: 3** corpus probes (`audit-tests-probes-rg49`,
  `purity-designer-y07`, `seams-surface-e07`). Each was rejected only
  by the unread-binding lint on `catch |e|`. That lint exempts a value
  that moves (`checkUnreadLocals`), and `error` now moves. Each runs
  clean. `reject/types/unread_pattern_bindings` drops its catch case
  for the same reason. **For the reviewer:** keeping the lint for
  `error` would need an exception to "a value that moves"; I kept the
  rule as written.
- No doc example, example, or suite test copies an error.

## Equivalence (test/equiv.py, base 54e4d16cc vs branch)

12,921 programs; 151 differ, every one in a class below (run first
against f026d177e: the same programs, less the new comparison test). No std module
and no JSON program differs.

- **Print by address (53 programs):** `print(e)` of a catch-bound error
  is `rig.print(.{ &e })`. `error` now moves, so `readByAddress` reads it
  in place, as for any owner (`storage.printsByAddress`).
- **Discard by address (37):** an unused parameter whose type mentions a
  type parameter, mostly a generic method's `self`, is `_ = &self;`
  (the unused-error-parameter fix: an instance may be an error).
- **Names table (2+):** a program that names a type parameter gains
  `.{ anyerror, "error" }` in `__rig_names`.
- **Storage facts:** every `catch |e|` capture prints `owned` for `copy`.
  **Sema facts:** a read `match e` on a caught error is a `viewed`
  header, as a read match of any owner is.
- **`==` on a branching error (1, the new test):** the operands are read
  in place (`readLeaf`), so the `??` value has a recorded use.
- **`match <e` (1, the new test):** an alternatives arm drops the whole
  value (`rig.discard`, a no-op for `anyerror`).
- **Diagnostics:** the new tests; the 4 corpus probes whose catch
  binding lint is gone (3 now accepted, `r3-s36-loans-f04` keeps its
  other error); `review-errors-b7` loses "incompatible types `error`
  and `Disk`" since a member meets `error`; `review-errors-b3` is
  rejected.
- **pkg only (4):** modules programs whose other module changed by a
  class above.
- **Docs (13):** the new SPEC/CORE examples, and SPEC/STD/SYNTAX
  examples in the classes above.

## Measurements (Mac, aarch64, `cpuq --cores 2`)

- **The L3 claim** (`errors/bench.zig`, ReleaseSafe, median of 5,
  instructions per iteration): A (today) 78.18, B (slot) 81.18, C
  (tagged Result) 79.19, against the proposal's 78.22 / 81.22 / 79.24.
  The disassembly confirms it: `b1` and `b2`, the `!` frames, are `a1`
  and `a2` instruction for instruction (28 each; the slot stays in x2).
  `b0`'s success path is `a0`'s (9 instructions); its failing path adds
  the 5 that write the slot, once per failure. The catch site costs
  B − A = 3.00 instructions per call.
- **R1 itself** changes no failing function and no `!` frame: no
  `return` or `try` line differs in the equivalence run.
- **`bench/json/guard.py`:** all six files within 0.4% (twitter 0.0%
  fewer, twitterescaped 0.0% more, canada 0.0% fewer, citm 0.1% fewer,
  gsoc-2018 0.4% more, github_events 0.0% fewer); std.json's Zig is
  unchanged.

## What R1 leaves ready for R2 (and #151)

The proposal's §7 puts "`error` usable as a type" in R1, so that is
built here. What #151 (Trig's glob) still needs is R2: `T!E`, and the
typed `catch |e|` binding, so `error_text(e)` takes a `GlobError`. R1
leaves: `error` in both grammar positions and the lexer; one owning fact
(`TypeInfo.any_error`, `sema.holdsAnyError`) that R2's typed binding
simply stops hitting (a field-less set is plain, so a typed `err`
copies again); `meets` from a set to `error`; `error!` rejected; the
oracle's kind; the matrix's `error` row; and P2, P4 and the type
rejections waiting as `rig pending` blocks in SPEC §13.

## In-flight branches

Facts this round changes: the per-type `moves` / `readByAddress` /
`cloneable` inputs (`TypeInfo.any_error`) and the catch storage label.
None of `closures`, `modules`, `simd2`, `inlinect`, `laneov`,
`constfold`, `small`, `trigfix` touches `moves`, `copies`, `cloneable`,
`holdsIn`, `TypeInfo`, or `error_value` (checked by diff against their
merge bases). `matchperf` merged first; this branch is merged with it.

## Gates

FILLED IN BELOW.
