# Review: cell-temp2, round 2 (e5111234, then 7fb643b4)

This is the second adversarial review of `cell-temp2`.

- Fix commit reviewed: e5111234, "Hold a catch handler's temporaries for
  its statement, give none leaves their own step, and end a statement's
  loans on a jump".
- Final head reviewed: 7fb643b4, "Address a branching value at its leaf
  in emitAddressOf too".

Setup:
- Worktree `scratchpad/ct2-review2`, with a Debug `bin/rig` and
  `bin/rig-oracle`.
- A ReleaseSafe compiler copied to `scratchpad/rs2/rig`.
- Main's compiler: `/Users/shreeve/Data/Code/rig/bin/rig` at 70fe1d2e.
- Probes: `.git/revamp/r3/probes/review-cell-temp2-2/`.

## Verdict

- **No soundness hole found at either head.** No accepted program used
  freed memory, leaked, dropped twice, wrote through a read view or into
  constant memory, or lost a Cell change. This holds in debug
  (`RIG_SANITIZE=1`) and `--release`, across:
  - 10,160 accepted grid programs (grid 1: 5,122; grid 2: 5,038);
  - 15 new hand probes;
  - every earlier round's probe.
- **No wrong output from the new rules.** The one ordering difference I
  found (L2) is pre-existing and the same on main.
- **No checker panic.** Every grid program was checked with both the
  Debug compiler and the ReleaseSafe compiler, which has bounds checks:
  - grids at e5111234: 0 panics;
  - 9,536 files of test/, examples/ and std/ at 7fb643b4: 0 panics.

  Round 1's H2 panic probes (c01–c04) all run correctly now. The checker
  no longer panics on main's c03 either.
- **No internal error is reachable from an accepted program.** The emit
  backstop gets 0 hits. Round 1's H1 `none` programs all run, and its L1
  Zig errors are gone.
- **One accept-means-correct failure at e5111234 (High H1), fixed at
  7fb643b4 and verified.** 11 grid-2 programs failed to compile in Zig.
- **One regression in what is accepted (Medium M1):**
  - Plain programs that main accepts are now rejected: a temporary made
    in a `match` arm that views the arm's binding.
  - The cause is the new rule that holds an arm's temporaries for the
    statement.
  - The oracle reports these programs as `stricter`.
  - The same placement on main left a view of a prong-local copy alive
    past the prong (Zig-level UB, no wrong output observed). So the
    branch's checker is right about what emit does. Emit's placement is
    what over-rejects.

Answers to the brief's questions:
- Soundness hole: **none**.
- Wrong output: **none from this branch**. L2 is pre-existing.
- Checker panic: **none**.
- Reachable internal error: **none at 7fb643b4**.
- Under the second-round rule, H1 counts as a correctness finding, not a
  soundness one: Zig refused to compile the program, so nothing ran
  wrongly.

## Method

| Run | Programs | Result |
|---|---|---|
| Grid 1 (`g1/gen.py single 8000 7`, the same programs as round 1, byte for byte), check | 8000 | Debug and ReleaseSafe: 0 panics, identical verdicts. 5,122 accepted (round 1: 5,009). 0 rejected that main accepts. Oracle: 0 differences |
| Grid 2 (`g2/gen.py single 8000 11`, the same as round 1), check | 8000 | 0 panics, identical verdicts. 5,038 accepted. 0 rejected that main accepts. Oracle: 0 differences |
| Grid 1, run (accepted programs grouped into 208 programs) | 5,122 | **all exact in debug (sanitizer) and release** |
| Grid 2, run without `none` (199 grouped programs) | 4,864 | **all exact in debug and release** |
| Grid 2, run with `none` (singles) | 174 | 163 exact. **11 Zig compile errors (H1)** at e5111234; all 11 exact at 7fb643b4 (`g2/results_fail11.txt`) |
| Round 1's hand probes (`review-cell-temp2/hand/p*`, `c*`), at 7fb643b4 | 27 | All accepted ones run correctly. c01–c04 no longer panic. p17 and p18 differ only from round 1's own `# expect:` blocks, which were wrong guesses; the corpus copies have the right output, which I re-derived by hand |
| Earlier rounds' corpus probes (`review-cell-temp*`, `review-cell-mut*`) and the two new behavior tests, at 7fb643b4 | 136 | All exact in debug and release. The 19 "mismatches" are only the oracle annotation lines after `# expect:`. 0 oracle differences |
| New hand probes `q01`–`q15` | 15 | See below. All accepted ones exact in debug and release, sanitizer-clean |
| `rig check` over test/, examples/ and std/ (Debug, ReleaseSafe, main), at 7fb643b4 | 9,536 | 0 crashes. Debug and ReleaseSafe agree everywhere. 88 newly accepted: the branch's own tests (10) and its corpus (78). **1 newly rejected**, `review-place-b11-z5` (round 1's L2, a safe tightening). Main panics on `review-cell-temp2-c03`; the branch runs it |
| Oracle on every probe | — | 0 differences, except `stricter` on q07 and q12 (M1) |

Reproduce:

```
cd .git/revamp/r3/probes/review-cell-temp2-2
./one_check.sh g2 <name>
./run.sh hand/qNN.rig
(cd g2 && ../one_run.sh fail11/<name>.rig both)
```

`run.sh` runs four checks on each file:
- `rig check` with main's compiler, the branch's Debug compiler and the
  ReleaseSafe compiler (it prints `RS-DIFFERS` when Debug and ReleaseSafe
  disagree);
- a `RIG_SANITIZE=1` debug run;
- a `--release` build and run;
- the oracle.

---

## High

### H1. A Cell member on a bare `Cell[T]?` that branches with a `none` leaf: a Zig compile error (fixed at 7fb643b4)

The implementing agent found this in my grid 2 at the same time I did.
It is the same class as round 1's H1: a second walk of a value's leaves,
beside `storage.leafStep`.

**Programs:** 11 grid-2 programs, listed in `g2/results_none.txt`:
- `s01112`, `s02964`, `s03383`, `s03833`, `s04456`, `s05828`, `s06505`,
  `s06789`, `s07269`, `s07491`, `s07498`;
- for example `((none if k else o) ?? mkww(5).t).set(77)`.

Hand forms are in `hand/q13_bare_cell_none.rig`:
- `((c if k else none) ?? Cell(0)).set(9)`
- `(c if k else none)?.set(9)`
- `((c if k else none) ?? return 5).set(10)`
- `.replace(7)` on any of these

Main rejects all of them ("`Cell.set` needs a Cell that has a place").

**Observed at e5111234:**

```
error: expected type '*T', found '*const T'
(&((if (k) c else @as(?rig.Cell(i64), null)) orelse rig.keep(...).*)).set(9)
```

**Root cause:**
- `emitCellAddress` called `emitAddressOf` on the whole branching
  expression. That left the address to Zig's result location (`&(if …
  else …)`) instead of `emitLeafPtr`'s walk.
- With named leaves only (`(c if k else d) ?? Cell(0)`), Zig's address
  of an `if` or `orelse` happens to point into `c` or `d`, so it worked.
- The `none` branch, written `@as(?T, null)`, is const, so Zig refused
  to compile it.
- Zig's constness is the only thing that stopped a silent copy here. A
  `&` of a branching value must never rely on it.

**Fix (7fb643b4):** `emitAddressOf` now sends any value that
`reachesLeaf` reaches to `emitLeafPtr`.

**Verified at 7fb643b4:**
- All 11 grid programs are exact in debug and release.
- q13 is exact:
  - every bare-Cell form above, for both values of `k`;
  - a `replace` that returns the old value;
  - a three-level `??` chain.
- Spot-checks of the sites the commit lists as audited:
  - `!` write lends of a made branch with a `none` leaf: `setopt`,
    `replace(!(mko(3) if not k else none), …)`, and `swap` on both
    sides. These keep the whole value in a slot. Afterwards, `none`
    leaves still read as none, so nothing was written into the
    `rig.noneAt` static (q13, and the `pre7` one-liners).
  - Read lends of branching temporaries with `none` leaves (`hitopt`).
  - `if (mko(3) if k else none) as y`.
  - `print` of a branch.
  - Array elements, and slices of branching array temporaries made in
    handlers (`(mkaf(-1) catch mka(30)) if k else arr)[0].hit()`).
  - Take-outs. Rejected as on main.

**Sibling note:** `rig.noneAt` returns a mutable pointer to a static.
That is safe only while no write ever reaches a `none` leaf by address.
Every write path I tried keeps the whole value in a slot instead. A
debug-mode assertion in emit, or a `*const` return for `noneAt` with a
`@constCast` only at the payload-capture sites, would make a future
mistake there loud instead of silent.

---

## Medium

### M1. A `match` arm's temporary that views the arm's binding is rejected; main accepts and runs it

**Probes:**
- `hand/q07_arm_view_regression.rig`: plain types with no Cell. Main
  prints the `# expect:` block.
- `hand/q12_arm_binding_view_drop.rig`: the same shape, where the
  temporary's `drop` reads the view.
- `hand/q06_arm_views.rig`: Cell-holder forms, which main rejects for
  other reasons.

**Command:** `bin/rig check hand/q07_arm_view_regression.rig`

**Observed (7fb643b4 and e5111234):**

```
q07_arm_view_regression.rig:23:42: error: `x` does not live long enough
  note: `x` goes out of scope while `HT(v: ?x, t: Text("abc"))` still views it
```

Also on `.has(x) => print("arm2", mkht(?x).t.len, len2(?mkht(?x)))`, and
on a `match` used as a value (`r = match b`, `.has(x) =>
len2(?mkht(?x))`).

**Expected:** accept and print as main does:

```
arm 6
arm2 2 5
none
none
5 5 -2
```

The oracle reports `stricter arms prod=reject ref=accept`.

**Root cause:**
- `walkMatch` now calls `holdPartTemps` for each arm body. It holds the
  arm's statement temporaries in hidden vars made *before* the arm's
  scope, matching where emit declares their slots: before the `switch`,
  dropped after it.
- The arm's binding `x` is declared in the arm's scope. A temporary that
  views it therefore outlives it, and `reportDropped` rejects the
  program.

**Why this is not simply a false alarm:** the branch's checker is right
about where emit keeps the temporary. Main's emit puts it there too:

```zig
var __rig_tmp_6: HP = undefined; ...; switch (mkbx(7)) {
    .has => |__rig_payload_7| { const x = __rig_payload_7.p;
        ... rig.keep(&__rig_tmp_6, ..., HP{ .v = &x, ... }) ... },
} if (__rig_tmp_6_live) { ...; rig.drop(&__rig_tmp_6); }
```

The slot holds `&x`, where `x` is a `const` local of the prong. In q12,
`HP`'s user `drop` reads `self.v.n` after the prong ended. That is a
dangling stack read, which is undefined behaviour in Zig. Main prints
the right values in debug and `--release` (`scratchpad/q12b.rig`), so
there is no observed wrong output. But main accepts it, and the branch
correctly refuses it.

**The over-rejection is the case where nothing reads the view at drop**
(q07: `HT` owns a `Text`, and its drop glue frees only that).

**Fix options:**
- **(a)** Keep an arm's temporaries in the arm, in both emit and the
  checker. This fixes main's latent UB without rejecting q07. It would
  make `stmtTemps` stop at arms, as at blocks.
- **(b)** Keep the current placement, and accept the rejection as the
  price of fixing main's bug. In that case, update the INTERNALS
  desugaring and the oracle's reference model, which still treats an
  arm's temporaries as the arm's. Otherwise the oracle gate reports
  every such program as a `stricter` difference.

Either way, this is a semantics choice, not a soundness hole.

**Siblings checked:**
- A `catch |e|` handler binds an `error` value. A view of it cannot be
  stored in a struct (`?error` is not a type), so the case cannot occur.
- A guard binding (`m if m > 0 =>`) viewed by an arm temporary works
  (q07 `arms4`), because the temporary views a value made in the arm.
- Handler and arm temporaries that view names outside the `match` or
  `catch` work (q08).

---

## Low

### L1. A `defer` that reads a name a jumping statement lent to write is rejected (pre-existing; a sibling of the "jump ends loans" fix)

**Probe:** `hand/q14_defer_on_continue_overreject.rig`:

```rig
for i in 0..3
  defer print("d", i, a.n)
  print(two(!a, maybe(i - 1) ?? continue))
```

**Observed:** "use of `a` while a write loan is live", on main and on
the branch.

At run time, the `continue` leaves the statement before `two` is
called, so the defer reads `a` with no loan. The cause is in `exitTo`:
it runs the jump's defers (`runDefersTo`) *before* the new line
`s.temps = to.temps` ends the statement's loans. The commit's rule
("a jump ends the loans the statement took") is applied after the
defers that the jump runs. `return` and `!` paths have the same order.
This is safe, but it is the same fact read at two points.

### L2. On an early leave, already-made arguments drop before a temporary made between them (pre-existing, same on main)

**Probe:** `hand/q15_early_leave_drop_order.rig`:
`tk3(P(n: 5), rp(?P(n: 6)), P(n: 7), maybe(i - 1) ?? continue)`.

**Observed:** `drop 7`, `drop 5`, `drop 6`, on both main and the branch.

**Per the SPEC (Temporaries):** temporaries drop "last made first, also
when the statement fails (`!`) or leaves early (`?? return`)". That
would be `drop 7`, `drop 6`, `drop 5`.

- The argument values are Zig locals of the call expression.
- The slot of `P(n: 6)` is a statement slot declared before them.

This is not a memory-safety issue, and it is not new. Either the SPEC
sentence should be narrowed (to slot temporaries), or emit should order
the drops. Out of scope for this branch.

### L3. `review-place-b11-z5` is newly rejected

This is round 1's L2, unchanged: `(<c).push(1)` is now rejected as a
move of a read-view receiver. It is a safe tightening, and the corpus
rule still holds.

### L4. The oracle still abstains on branching Cell holders

It returns `ref=unknown` on every new probe's Cell functions. Its only
signal this round is `stricter` on M1.

---

## Attacks that held (all exact in debug and release, sanitizer-clean, 0 oracle differences)

### The new catch-scope rule (`holdPartTemps`, `sema.stmtTemps`)

- `q01`, handlers in loops:
  - `for` and `while` loops;
  - under `defer`, with `.me().me()`;
  - nested `catch` inside `catch` (three levels, with `catch |e|` /
    `catch |f|` both read);
  - owning `Vec` values from nested handlers, moved with `<`.
- Views of handler temporaries that escape the statement are **all
  rejected** ("a view of the temporary … outlives its statement"):
  - bound to a name;
  - assigned to an existing view;
  - pushed into a `Vec[?D]`;
  - a ternary of views;
  - `.me().me()`;
  - through `??`, nested `catch` and a part leaf `mkww(5).t`;
  - from a `match` arm;
  - from an `if` block branch;
  - a `break` value out of a value loop;
  - a closure's return value.
- `q04`, handlers that jump:
  - `catch (… ?? continue)`, `catch (… ?? break)`,
    `catch |e| (… ?? return 7)`;
  - with `defer`s in the function;
  - handlers in `match` arms in a `while`, with `continue` and `break`.
- `q05`, handlers making owning values (`D`, `Vec`, `Text`) that are:
  - moved into bindings, `Vec`s and struct fields;
  - passed by value;
  - or dropped.
- `q11`, temporaries whose user `drop` reads a view of another
  temporary of the same statement, made in handlers and `??` fallbacks,
  in loops. The viewer always drops first. This checks that
  `stmtTemps`' declaration order matches evaluation order.
- Temporaries sharing a start position (`mk(5).cp().cp()` in a
  handler), since `stmtTempAt` looks them up by position. Each was
  dropped once, in order.
- `q10`, handler temporaries in headers: a `while` condition each
  iteration, an `if` condition, a `match` subject, a `for` range, and an
  `if` condition with `?? continue`.

### The jump change (`s.temps = to.temps`)

- `?? continue`, `?? break` and `?? return` in arguments after these
  earlier arguments:
  - `!a`;
  - `?a`;
  - a `<b` move;
  - a handler-made owner;
  - a `?mk()` lend;
  - `mk(6).cp()`.
- A name used after the jump, and a write-lend held by a struct
  (`h = HV(v: !a)`), which is still rejected.
- Value loops: `r = for … break two(!a, n)` after `print(rd(?a, n),
  maybe(j - 2) ?? continue)`.
- Loops cannot appear inside an argument (the grammar rejects it), so
  no jump target lies inside a statement with outstanding loans.
- No leak, no double drop. For example, a moved `<b` whose argument
  jumps is dropped once.

### `none`

- `q03`, every one of these at all four `(k, j)`:
  - `none` at depth 1–3 under `?`, `?.`, `??` (left, right and chained);
  - all-`none` sub-branches;
  - `none` beside made leaves and named leaves;
  - by-value `??` with made leaves;
  - bare `Cell[Int]?`, and a struct-holder `?.c.set`.
- `q09`: `none` as a `catch` handler's value for `D?!`, under `??` and
  `?.`.
- `q13`: as above.
- Round 1's p12, p13, p14, p22 and p23 are exact.
- Grid 2's 163 non-H1 `none` programs are exact.

### Over-rejection against main

0 in either grid. Over test/, examples/ and std/, only the corpus file
in L3. M1's shape does not occur in the suite.

## Files

- `run.sh`, `par.sh`, `sum.sh`: per-probe runs (as in round 1, plus the
  ReleaseSafe check).
- `one_check.sh`, `check.sh`: grid checks (Debug, ReleaseSafe, main,
  oracle).
- `one_run.sh`, `run_all.sh`: grid runs.
- `tree_check.sh` and `tree_results.txt`: test/, examples/, std/.
- `g1/` and `g2/`:
  - `gen.py`;
  - `single/`, `multi/` and `nonesingle/`;
  - `check_results.txt`;
  - `results_*.txt`;
  - `fail11/` (H1).
- `hand/`:
  - `q01`–`q15`, with `# expect:` blocks where accepted (each verified
    by hand);
  - preludes `pre*.rig`;
  - `one.sh` (one-statement checks on all three compilers).
- `logs-q/`, `logs-r1hand/`, `logs-corpus/`: probe logs at 7fb643b4.
