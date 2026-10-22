# Review round 2: `move-done` at c1a7d3f4 (base c169ec89)

Reviewer: independent adversarial review, second round. Probes are in
`.git/revamp/r3/probes/review-move-done-2/`. `run.sh` there runs each
probe four ways: a check with the base compiler, a check with the
branch, a sanitized branch run when the branch accepts, and
`rig-oracle -v`.

Binaries:
- branch: `rig-move-done/bin/rig` and `bin/rig-oracle`, rebuilt at
  c1a7d3f4 (`zig build` and `zig build oracle` were no-ops);
- base compiler: `probes/review-move-done/bin-main/rig-c169ec89`;
- base oracle: `probes/review-move-done-2/bin-base/rig-oracle-c169ec89`,
  built from `git archive c169ec89`. I used it to tell which oracle
  differences are older than this branch.

## Verdict

**No soundness hole remains through `<`.**
- I found no accepted program that moves an owner out of something that
  still drops it.
- I found none that empties a place a live view reads.
- I found none that double-drops.

The C1/C2 class from round 1 is closed in every carrier and every
wrapper I generated. Every accepted cell runs sanitizer-clean.

**The oracle hard gate still fails, on two forms.** Both forms are
older than this branch: the base compiler accepts them, and the base
oracle rejects them. Both are memory-safe. Both are in the class this
PR claims to own, "what `<` does to its source". Under the gate, a
prod-accepts difference cannot be allowlisted, so each needs a decision
before merge (H1, H2).

Three smaller rule and consistency points follow (M1, L1–L3).

Under "a second soundness round stops the feature", no **soundness**
fix is needed this round. The open items are rule consistency and the
oracle model, not memory safety.

---

## Method

### The generated grid (`grid.py`)

`grid.py gen DIR` writes one program per cell. Each cell is a function
`cell(c, p: ?S, q: !S)`. After the carrier runs, the cell reads the
container it moved from through `lks(?s)`, which touches every field's
buffer. A source left freed is therefore a use of freed memory, not
only a leak.

The axes:

- **Element type T (7):**
  - `Int`;
  - a plain struct `P` with `into(<self)`;
  - `Text`;
  - `Vec[Int]`;
  - `HV`, a struct holding a Vec, with `into(<self)`;
  - `D`, a struct with a `drop` body and `into(<self)`;
  - `*N`.
- **Sources (40):**
  - a binding, and an optional binding;
  - a field, a nested field, an optional field, and a nested optional
    field;
  - an element and an optional element, of a Vec and of an array;
  - a field and an optional field of a Vec element;
  - a made value and a made optional;
  - parts of a made value: `mks(1).f`, `mks(1).o`, `mks(1).w.f`;
  - `*T` parts: `h.f`, `h.o`;
  - `?S` parameter parts: `p.f`, `p.o`;
  - `!S` parameter parts: `q.f`, `q.o`, `q.w.o`;
  - parts through a lend: `(!s).f`, `(!s).o`, `(?s).f`, `(?s).o`;
  - parts of a call returning a view: `gw(!s).f`, `gw(!s).o`,
    `gr(?s).f`, `gr(?s).o`, `gw(q).f`, `gw(q).o`;
  - parts of a branching value: `(s if c else s2).f`, `.o`,
    `(v if c else v2)[0]`, `(so ?? s2).f`, `(!s if c else !s2).o`,
    `(mks(1) if c else mks(2)).f`.
- **Wrappers (10):** none, parentheses, `if`/`else` (source left and
  right), `??` (source left and right), `catch`, `?`, a call argument
  `idf(X)`, and a nested `if`.
- **Carriers (16):**
  - `x = <e`;
  - `f(<e)`;
  - `return <e`;
  - `break <e`;
  - `for x in <e`;
  - `match <e`;
  - `if <e as x`;
  - a constructor field;
  - an array literal;
  - `<e.into()`, and `e.into()` with no `<` (the M1 fix);
  - `defer`;
  - closures `|!r|`, `|<r|`, and `|?r|`;
  - `*<e`.

`match` is generated for `Int` only, since `match` takes no other
generated type. Block-form `if`/`match` cannot be an operand of `<` at
all: the parser rejects them (`a01`–`a05`).

The grid has **28,815 cells**. Each was checked with the branch, the
base compiler, and the branch oracle, through `heavy.sh`. Every
branch-accepted cell was then run with `RIG_SANITIZE=1`. The results,
one line per cell, are in `grid-results.tsv`.

| base → branch | cells |
|---|---|
| accept → accept | 3,618 |
| reject → accept | **67** |
| accept → reject | 9,666 |
| reject → reject | 15,464 |

- **Sanitized runs:** 3,685 / 3,685 clean. Every one exits 0, with no
  leak, no use of freed memory, and no crash. Every `D` cell printed
  its drops.
- **reject → accept (67):** all are `P` (copies) consuming-receiver
  cells: `s.f.into()`, `(s.f).into()`, and receivers through `?S`,
  `!S`, a lend, a view result, a `*T` part, or a branch. Two shapes
  appear:
  - the M1 fix, which reads a copy;
  - `<(X).into()`, which parses as `<` of the call's result, a made
    `Int`.

  All run clean.
- **accept → reject (9,666):** every first error is one of the rule's
  ten diagnostics: "it copies", "`<` here would copy … take/move it
  inside the branch", "`<` here would leave … as it was", "… before
  the `?` or `!`", "cannot move a part out of the temporary", "cannot
  take out of a temporary", and "`…` reads a binding where it stands".
  None is a stray rejection.
  - 4,731 of them are owning types that base accepted.
  - I sampled base runs of four: `vec/brlend.catch.arg`,
    `vec/brelem.catch.arg` (copied in as
    `grid_vec_brelem.catch.arg.rig`), `vec/mparto.catch.arg`, and
    `vec/brelem.none.arg`. All four are uses of freed memory on base
    (`rig: use of freed memory`, then a bus error). The branch
    closes real base holes beyond the ones the PR names: `catch`
    handler leaves that are parts of a branching value, or optional
    parts read through views.
- **What the branch accepts for owning T** is exactly:
  - `<binding`;
  - a made value, alone or as every leaf of a branch;
  - `<` of an optional part of a place, directly or through a write
    view (`(!s).o`, `gw(!s).o`, `q.o`, `q.w.o`, `|!s|` capture), or
    through a branching write lend (`(!s if c else !s2).o`).

  Nothing else is accepted.
- **Oracle:** 126 DIFFs, all of them `brlend` cells (H1).

### Hand probes

| Probe | What | Result |
|---|---|---|
| `e01_take_under_view` | take while a view of the payload or place is live: `if ?s.o as y`, `if !q.o as y`, `for e in ?v`, a `?w.o` view of a `!S` result, a `|?s|` closure | all rejected; oracle agrees |
| `e02_take_index_effects` | `<v[grow(!v)]`, where the index pushes 100 elements | accepted, runs clean; oracle unknown |
| `e04_take_handle_lend` | `<(!h).o` with `h: *S` and a second handle | rejected |
| `e05_take_args_order` | `both(?s.o, <s.o)`, `!s.set(<s.o)`, `!v.push(<v[0])`, `both2(<s.o, ?s)` | the first three rejected, the last accepted and clean; oracle agrees |
| `v01_branch_of_view_bindings` | `<(r1 if c else r2).o` with `r1 = !s`, `r2 = !t`; `<r1.o` | accepted, clean; **oracle DIFF** (H1) |
| `v02_view_fields`, `v03*` | takes through a `!S` held in a field, a Box, a `for e in !v` element; `?S` field and owning part through `!S` field rejected | correct; oracle agrees |
| `p01`, `p02` | `match !e` payload take, `for s in <v` then `<s.o`, `while <s.o as x`; read payload take rejected | correct; oracle agrees |
| `h01_weak_cell_parts` | `<(w.upgrade()?.o)`, `<(w.upgrade()?.v)` | rejected (wording, L3) |
| `g01`–`g04` | generic: `<g.f` where an instance makes `f` optional, `for x in <g.f`, `<(a if c else b)` and `<(o ?? a)` over `T`, a generic made part as a leaf | all rejected in the generic body |
| `d01_declared_carriers` | `for x in <K`, `|| eat(<N)`, `<one`, `<(N if … else 4)` | rejected |
| `c01_closure_capture_move` | `|<v| eat(<v)` called twice | rejected; oracle agrees |
| `r01_copy_capture_move` | `|+n| twice(<n)` called twice | accepted, prints `6 6 3`; **oracle DIFF** (H2) |
| `r02_take_temp_through_lend` | `<(!mks(1)).o`, `<gw(!mks(2)).o` | accepted, clean (M1) |
| `m01`–`m07` | the consuming-receiver copy (item 3, below) | see below |

Round 1's probes, rerun on c1a7d3f4:
- p62, p63a–e, p64, p66, p67 (C1/C2) and p46/p47 (round 1's H1) are
  now rejected;
- p70 is now accepted (M1, as intended);
- no oracle DIFF remains in `probes/review-move-done/`.

---

## High

### H1. `<(!s if c else !t).o` is a compiler-accepts / oracle-rejects DIFF (hard gate; older than this branch)

Probes:
- `grid_vec_brlend.none.bind.rig`, `grid_drop_brlend.paren.ret.rig`;
- all 126 `brlend.{none,paren}.*` cells (`grid-oracle-diffs.txt`);
- `v01_branch_of_view_bindings.rig` (`<(r1 if c else r2).o` with
  `r1 = !s`, `r2 = !t`).

```
cd .git/revamp/r3/probes/review-move-done-2
./run.sh grid_vec_brlend.none.bind.rig v01_branch_of_view_bindings.rig
bin-base/rig-oracle-c169ec89 -v v01_branch_of_view_bindings.rig
```

- **Observed:**
  - base and branch both accept;
  - the sanitized run is clean, and the right place is emptied
    (`false true false` / `false true true`);
  - the branch oracle and the base oracle both report
    `DIFF … prod=accept ref=reject C7 nothing is taken out through a
    read view`.
- **Expected:** compiler and oracle agree.
- **Root cause:** `moveSource` classifies the operand as
  `optional_part`. `pathHands` makes a path through a branching value
  of view type a `.place`, so the operand is a take through a write
  view, which is sound. The oracle (`test/oracle/lower.zig`) types a
  branching value of write views as a read view. The fix belongs in
  the oracle, which should model `a if c else b` of `!S` as a `!S`.
  The alternative is a deliberate compiler rejection of a take through
  a branching view.
- **Corpus:** no corpus probe covers this form accepted. The nearest,
  `review-seam2-r2-w05_coalesce2.rig`, takes the owning `.items`, which
  is rejected.

### H2. `<n` of a copy capture leaves the capture as it was, and is an oracle DIFF (hard gate; older than this branch)

Probe: `r01_copy_capture_move.rig`.

```rig
n = 3
g = |+n| twice(<n)
print(g(), g(), n)        # 6 6 3
p = P(v: 4)
h = |+p| eat(<p)
print(h(), h(), p.v)      # 4 4 4
```

- **Observed:**
  - base and branch accept;
  - the program runs clean;
  - both oracles report `DIFF … prod=accept ref=reject B3 a closure
    does not move or drop `n`, which it captured`.
- **Expected:** rejected, under the rule this PR states: "`<` always
  leaves its source done: a name is ended". The closure's environment
  keeps `n`, and each call moves a fresh copy. This is the same shape
  as round 1's H1 (`<` that silently copies). An owning capture is
  already rejected (`c01`: "cannot move captured resource").
- **Root cause:** `moveSource` returns `.binding` for a `.capture`, and
  ownership's `moveVar` lets a copy-typed capture "move" without ending
  anything, since the environment is re-entrant. The fact and its
  consumer disagree on what `.binding` means for a capture.
- **Fix:** reject `<` of any capture with the copy wording ("the
  closure may run again; remove the `<` to copy it"). The other choice
  is to make it a `MoveSource` case of its own (`declared`-like). Add
  it to `move_part_that_copies.rig` or a sibling test.

---

## Medium

### M1. `<` of an optional part of a made value is accepted when reached through a write lend

Probe: `r02_take_temp_through_lend.rig`.

```rig
a = <(!mks(1)).o          # accepted: empties a field of a temporary nothing sees
b = <gw(!mks(2)).o        # accepted
c = <mks(3).o             # rejected: "cannot take out of a temporary: nothing would see it emptied"
```

- **Observed:** base and branch accept a and b, and both run clean.
- **Expected:** under CORE §5 as edited ("any other place is rejected,
  a part of a value made there too"), `<` on a part of a made value is
  rejected however it is reached. The PR text claims that
  `requireAccess(.take)` rejects "a temporary behind a lend". It does
  not: `place.indirect` returns true before the `.temporary` arm can
  reject.
- **Root cause:** `pathHands` makes a path through a view a `.place`,
  so `moveSource` cannot see the made value behind the lend. This is
  correct for views of real places, but here the view's root is a
  temporary.
- **Impact:** not a soundness issue. The rule has one more unstated
  exception, and the PR's description of `requireAccess` is inaccurate.
- **Fix, either of:**
  - reject, by `requireAccess` honoring a temporary root behind a lend
    for `.take`, or by `moveSource` asking for the lend's operand;
  - state the exception in SPEC and the PR, and correct the PR sentence.

---

## Low

### L1. Two "may `<` take" decisions still live outside `moveSource`

The grep for `tempBase`, `needsCleanup`, `movedTail`, `takeable`,
`.take`, and the consuming-receiver logic finds:

- **`typecheck.payloadViewTaken`** (called first in `synthMove`) rejects
  `<y` of a read payload binding of `match`. `moveSource` calls the
  same node `.binding` ("ended"). This is stricter than the fact, never
  looser, so it cannot make `<` unsound. It is still a second
  classifier for one `.binding` sub-case, and it should be a
  `MoveSource` case or be named in INTERNALS.
- **`requireAccess(.take)`** decides writability of an
  `optional_part`. This is legitimate typecheck work, but it is where
  M1's gap lives.
- The other sites do not decide the fact:
  - `tempBase` remains only in the `for` read/iter header and in
    `match` arm bindings, and decides whether a view outlives a header
    temporary;
  - `needsCleanup` decides discards and array temporaries;
  - `takeableSubject` builds a hint;
  - emit reads only `takes` (`emit.zig:3793`);
  - storage reads `.move` / `takesSubject`.

The typecheck and ownership answers cannot disagree: both call
`sema.moveSource` on the same node, after `synthExpr` has recorded the
operand's types. In a generic body, `typeOf(g.f)` stays `T` (`g01`:
`<g.f` is `.part`, rejected, not `.optional_part` from an
instantiation).

### L2. Consuming receiver (the round-1 M1 fix): sound, with one inconsistency

`checkReceiverMode` reads a copy only when `sema.copies(recv) == .yes`.

| Probe | Receiver | Result |
|---|---|---|
| `m01` | a copying struct holding `?Vec[Int]` | the copy keeps its loans: `v = mkv(6)` after `x = s.rv.into()` is rejected ("cannot reassign `v` while it is lent"); oracle agrees |
| `m02`, `m07` | generic `T` | not reachable: "a generic parameter `T` has no methods" |
| `m03` | `*T` | rejected ("cannot consume … through a shared handle") |
| `m04` | a struct holding `!Int` | does not copy, so rejected (no copy of a write view) |
| `m06` | a struct holding a Cell | does not copy, so rejected |
| `m05` | `s.p.into()` through `s: ?S` or `s: !S` | accepted (copy) |

The inconsistency is in `m05`: `p.into()` with `p: ?P` or `p: !P` is
still rejected ("cannot consume through a view"), although a view of a
value that copies is copied out elsewhere (Core sentence 1). This is an
older message, not unsound.

### L3. Wording

- `<(w.upgrade()?.o)` says "cannot take out of a temporary: nothing
  would see it emptied" (`h01`). But the base is a `*S` handle whose
  box other handles see. Base said "cannot take through a shared
  handle", which was more accurate.
  - **Root cause:** `w.upgrade()?` is all-made, so `.made_part`
    without a check for a handle-typed base.
- `moveLeaves`' `declared_within` exemption (a block's own local at a
  branch tail) is unreachable for inline operands: block-form
  `if`/`match` cannot follow `<` (`a04`, `a05`), and `<f() catch |e|
  …` parses as `(<f()) catch`. It is harmless, but untested.

---

## Hard gate summary

- **compiler-accepts / oracle-rejects:**
  - H1: 126 grid cells and `v01`;
  - H2: `r01`.

  Both are older than this branch (the base oracle reports them too),
  and both run clean.
- **No other DIFF** in the grid, my hand probes, or round 1's probes
  on c1a7d3f4.

## What holds

- C1/C2 are closed. `for x in <`, every `if`/`??`/`catch`/`?` leaf,
  and nested and parenthesized wrappers all reach `moveSource`. All
  7 types × 16 carriers agree.
- Takes conflict correctly with every live view I tried: payload
  views, loop views, closure lends, view results, and argument order.
- `<` of a module constant or a function is rejected in every carrier
  (`d01`).
- In generic bodies, `<` of a part, a branch leaf, or a made part is
  rejected before instantiation.
