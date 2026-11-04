# Review of PR #931 (rv-patterns @ bdd40424c)

Probes: `scratchpad/probes/*.rig`, runner `probes/run.sh` (check, oracle, debug,
release, RIG_SANITIZE=1). The reviews' generators, repointed at this build:
`scratchpad/pr/formal/gen.py`, `cover2.py`, `soundness/run.sh`, and a new
`pr/formal/gen3.py` (three optional fields, same-variant alternatives, guards, a
trailing `_`, a binding read in the body; the verdict is checked against the exact
cell model, then every accepted program runs).

## What holds

- **equiv** (formal gen.py): 643 cases (453 single patterns and 190 alternative lists)
  x 15 values x 5 forms gave **0 disagreements**. Main had 85 Zig failures (A3).
- **cover**: 819 of 819 verdicts agree. cover2 finds 0 accepted with a dead arm and
  226 of 226 dead arms reported as dead.
- **gen3**: 6,000 sequences over 3 seeds gave **0 verdict mismatches** against the
  cell model. Every missed value the message names really is uncovered. All 576
  accepted programs run and pick the right arm.
- **soundness probes**: 194 probes. F1, F2, F3 and F5 are fixed. F4 is fixed except
  in generics (issue 3). Every program that runs gives the same output in debug,
  release and sanitize. Drops come at the end of the block in `if`/`while`/ternary
  under `<s` (p34, p35).
- **The new prongs.** The read, `!s` and `<s` prongs I read are right: `somePtr(&s.a.t).?`,
  `rig.some(w.a.t).?`, one prong per variant for same-variant alternatives, and
  `else` only when variants are left out (o01, o02, g05, g08). Constants after
  `matches` work (k01, k03).
- **emit-diff and the corpus.** emit-diff could not have tested the new prongs:
  examples, std, bench, Trig and loco contain no alternatives that bind. Its
  identical result shows only that the `fieldRead` refactor of single patterns is
  byte-identical.

## Issues

### 1. CRITICAL (North Star 2), on main too: the ownership checker ignores names bound by alternatives
- `src/ownership.zig:7501` `bindPattern`: the `.list` case handles `variant_pattern`
  and `set_pattern`, but not `alt_pattern`. A name that alternatives bind never
  becomes a var: it takes no loan on the subject and is never marked as moved.
  The oracle abstains, so it cannot catch this (`test/oracle/lower.zig:1796`,
  "alternatives that bind").
- Probes, each accepted:
  - `v8`/`v5`/`x1`: reassigning `s` while `t` lives gives a sanitizer "use of freed memory".
  - `x3`: `eat(<t)` then `print(t)`: use after move.
  - `x5`: `!ys.push(<t)` twice: "double free" panic in debug.
  - `w1`/`w3`: `eat(<s)` inside the body.
  - `x4`: `print(s)` while `t` is a `!` view.
  The same code with one pattern (`v1`, `x2`, `w4`) is rejected.
- **This PR turns some Zig errors into silent UAFs:** `v5`
  (`if s matches (.a(t?), .b(t))`, then `s = …`, then `print(t)`) failed in Zig on main
  ("unreachable else prong") and now runs into freed memory.
- **Fix:** in `bindPattern`, bind the leaves of the first alternative that binds
  (the symbols are shared, as in emit's `firstBinding`). Teach the oracle
  alternatives (bind the first one's leaves). Add these probes as `fail` cases.
  This should block the merge, or land first.

### 2. HIGH (North Star 1 and 4), on main too: emit decides `name?` unwrap by type depth
- `src/emit.zig:5068` `unwrapsField` compares the optional depth of the declared
  field type with the bound type's. Under a generic instance whose `T` is
  optional, those depths differ from what the pattern tests:
  - `g07`: `E[Int?]` with `.b(n?) => n` gives "expected i64, found ?i64".
  - `g09`: `.a(m?)` on `n: T?` gives "invalid operands … optional".
- The PR's own `altReads` reads the recorded fact (`payloadTests[i] == .some`), and
  the same program with alternatives runs (`g08`). That leaves two classifiers for
  one fact.
- **Fix:** use `payloadTests` at `emit.zig:5212`, `5407` and `5609`, and delete
  `unwrapsField`.

### 3. MEDIUM (North Star 1): F4 still fails in generic bodies
- `p21_generic`, `p21b`, `p22d`: `fun get[T](e: ?E[T])` with
  `.left(v), .right(v) => 1` and `v` unread is accepted. Zig then fails with
  "unused local constant", on main and here.
- `src/storage.zig:1462` marks a symbol as used at any of its names that is not its
  declaration, so a later alternative's leaf counts as a use. The lint skips
  generic bodies.
- **Fix:** skip the leaf positions of later alternatives there: give
  `bindPattern` (resolve.zig) its own set, apart from `unread_names`, because
  assignments must stay uses.

### 4. HIGH (North Star 1), on main too: payload tests on an error member's optional field
- `e1` to `e4`: `.bad(_?)`, `.bad(n?)`, `e matches .bad(none)`, and
  `if e matches .bad(n?)` on `error E { bad(n: Int?) }` are accepted. Zig fails
  with "type 'anyerror' does not support field access".
- The PR's own comment at `typecheck.zig:3782` says "emit lowers no payload test of
  an error's member".
- **Fix:** in `checkVariantPattern` (`typecheck.zig:4755`), when the subject holds
  errors and the pattern tests a field, reject it ("an error's field is read
  with `n`, then tested `n == none`"). The other way is to lower the test.
  Coverage then needs no `errors` special case.

### 5. LOW
- `k02`: `n matches k` with a local `k` adds a spurious "`k` is assigned but never read".
- Under `<s`, a failed condition drops the value before `else` runs (`o01`, s4).
  That fits "moved", but SPEC does not say so.

No coverage issue found: no accepted match misses a value, and no complete one is
rejected.

## Re-review of item 1 at 639b1fb3a: fixed

bin/rig and bin/rig-oracle were built after the head commit.

- **The first round's probes.** All 13 are now rejected by the compiler and by the
  oracle, with the same reason: `v4`, `v5`, `v7`, `v8`, `v9`, `x1`, `x3`, `x4`,
  `x5`, `w1`, `w2`, `w3`, `o07`. That covers reassign while viewed, use after
  move, double move, a move or write lend of the subject, and reading `s` under
  a `!` view.
- **New probes** in `scratchpad/probes/r2/`, all using alternatives with `t?`, under
  `?s`, `!s` and `<s` subjects, in `if`, `while`, ternary and arms:
  - **14 misuses rejected.** Both checkers agree on each one the ownership pass
    reaches:
    - reassigning or reading `s` under each subject sigil (R01, R02, R10, R11);
    - a moved subject used again, in a `while` (no reassign), a ternary or an arm (R03, R04, R13);
    - a view escaping into an outer list or a returned view (R06, R12);
    - `<t` moved twice in a loop (R08), and moving `<s` behind a guard (R09);
    - a closure capturing by move, then `t` used (R14).

    R07 is a type error. In R05 the escaping closure is rejected in `mk`.
  - **10 valid programs accepted** (A01 to A10), and both checkers accept each.
    They cover:
    - loops that write, and loops that consume and reassign;
    - a ternary that consumes;
    - local closures, both read and move captures;
    - clone escapes;
    - returning a view `from s`;
    - `<s` with the name left unmoved.

    Each runs with exit 0 and identical output in debug, release, and
    RIG_SANITIZE=1, with no leak.
- R05's main shows an oracle DIFF (prod=accept, ref=reject). The single-pattern
  version shows the same DIFF, so it is not about alternatives, and the program
  is rejected in `mk` anyway.

**Verdict: item 1 is fixed.** I found no hole that is specific to alternatives.
