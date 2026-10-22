# Study: write views held in bindings (rules 3 and 4)

Measured on `main` a7ac9080, 2026-10-09, on a local throwaway branch. Nothing was merged or pushed to origin. The method follows `study-mutation-never-data.md`.

## The verdict

1. **Rule 3 is the rule that closes the classes.** With rules 1+2+3, 9 of the 11 Critical/High write-view findings become unwritable, every probe of each. This covers payload-loan-4 C1/C2, payload-loan-5 C1/C2, and header-paths-1 C1/C2. Rule 3 alone makes 102 of the 145 probes unwritable.
2. **Rule 4 adds little.** Alone it fully closes one finding (payload-loan-3 H1, which rule 1 also closes) and finishes payload-loan-3 H2, whose other half rule 1 already takes. Every other `(!T)?` probe is already rejected by rule 1 or 3. It costs 24 programs beyond rules 1+2, all tests or probes, and it deletes the `as` copy-out path (`Facts.readsThroughWrite`, ~50 lines).
3. **Together, rules 1+2+3+4 close 10 of the 11 compiler findings (133 of 145 probes).** The one class left is syntax-b-2 C2, the loan of a `match !x` payload binding (0 of 12 probes). Neither rule touches it: its subject is a name, not a branch, and its binding is `!T`, not `(!T)?`.
4. **Rule 3 as written is broader than the bug.** The bugs all come from a branch with a place leaf (a name or field holding a write view). 244 of the 265 programs it newly rejects have only made leaves: `!a if c else !b`, `getw(!x) catch !y`, `<(!p if c else !q)`. That includes the documented SPEC form `(!a if c else !b).x += 1`. A narrower **rule 3p** (reject the branch only when some leaf is a place) closes exactly the same 102 probes, and newly rejects 21 programs instead of 265.
5. **No curated code breaks.** examples/, std/, and every doc but one SPEC example are untouched. **Recommendation:** adopt rule 3p, not literal rule 3. Literal rule 3 also makes a `(!T)!` result unbindable: `w = f()!`, `catch` and `e?` over a call are branches with made leaves. Rule 4 is optional: it is cheap and deletes ~50 lines, but closes nothing that rules 1 and 3 leave open. syntax-b-2 C2 needs its own rule about `match !x` bindings.

**Key numbers** (programs main accepts: 9,900; rules 1+2 keep 8,259):

| | Newly rejected beyond 1+2 | Of those, outside corpus and probes | Findings fully unwritable (of 11) | Probes unwritable (of 145), counting rules 1+2 too |
|---|---|---|---|---|
| rules 1+2 (baseline) | — | — | 3 | 60 (41%) |
| rule 3 | 265 | SPEC 1, behavior 13, lendw 12 | 9 | 133 |
| rule 3p (place leaf) | 21 | behavior 1 | 9 | 133 |
| rule 4 | 24 | behavior 1 | 4 | 68 |
| rules 3 + 4 | 282 | SPEC 1, behavior 13, lendw 12 | 10 | 133 (92%) |

## Setup

- **Build.** One instrumented compiler on local branch `study2-main` (a7ac9080 + `src/study.zig` + probes). It ran in report mode (`RIG_STUDY=report`): each rule's hits are printed and no verdict changes. Every configuration is computed from that one sweep. A program is rejected under a configuration when main rejects it or one of its rules hits. `RIG_STUDY=enforce:1234` turns the hits into errors, and the rewrites below were verified with it.
  - Because of this, separate `study2-exp3/-exp4/-exp34` branches were not needed. One binary measures every configuration, so the configurations differ only in the rules counted.
- **Rule 1** (write view never data, without the strict closure rule) and **rule 2** (Cell only behind `*`) are rebuilt as in the previous study.
  - One change: rule 1 sees a write view through views and handles too, so a `?((!P)?)` parameter is nested and rejected.
  - Their fallout matches the previous study: SPEC −8, CORE −1, SYNTAX −1, behavior −125. The corpus count is a little lower than before (−664), and the 105 + 12 closure-only flips are gone.
- **Rule 3, a branch over write views is never a place.**
  - **What it checks:** an `if`/`else` value, `??`, `catch`, `e!`, `e?`, a `match` used as a value, or a loop value (`break v`), whose type holds a write view, and which is not itself a part of an enclosing branch.
  - **Exempt:** the result of a function, closure, or `return`. A function may return `m if k == 0 else none`.
  - **Allowed uses, the positive list:**
    1. A field or index path off it whose value copies (`copies == .yes`), used where it is only read: a `print` or other argument, a binding, an operand, a header subject that copies, or `for x in` (iterate mode). For example `print((a if c else b).n)` or `x = (a if c else b).n`.
    2. The whole branch, where typecheck records that its context reads the copied value (`ViewRead.slot` or `.value`): `y = m if c else k` with `!Int` leaves gives an `Int`.
  - **Rejected:** everything else. That is: binding or passing it as a view, `match`/`as`/`for` over it, a lend `?B`/`!B`, a move `<B`, a method receiver, an assignment through a path (`(!p if c else !q).x += 1`), and a lend, move, or method call on a part.
  - **Leaves are classified** as a place (a name or a field/element path) or made (a `!x` lend, a call, `<w`). **Rule 3p** is rule 3 restricted to branches with a place leaf.
- **Rule 4.** A local, capture, pattern, or `as` binding whose type is `(!T)?` or `(!T)!` is rejected. Parameters and results are allowed.
- **Sweep:** `rig emit` over 21,668 programs, on pup through `pup.sh` (under cpuq). Results are rechecked on the Mac for the forms below. The programs are:

  | Source | Programs |
  |---|---|
  | tracked `.rig` files in test/, examples/ and std/ | 11,720 |
  | doc examples | 361 |
  | original review probes (payload-loan-1..5, syntax-b-2, header-paths-1 with its grids) | 1,930 |
  | `test/matrix.py` cells | 7,501 |
  | `hdr.` cells, generated from the `header-paths` branch's `matrix.py`, since `hdr.` is not on main | 156 |

## 1. Fallout

Programs main accepts that each rule rejects. "new" means beyond rules 1+2. Groups with no change are left out.

| Group | Accepted on main | Accepted under 1+2 | Rule 3 (of main's accepted) | Rule 3 new | Rule 3p new | Rule 4 (of main's) | Rule 4 new | 3+4 new |
|---|---|---|---|---|---|---|---|---|
| doc/SPEC | 116 | 108 | 1 | 1 | 0 | 0 | 0 | 1 |
| test/behavior | 1067 | 942 | 18 | 13 | 1 | 3 | 1 | 13 |
| test/corpus | 4244 | 3580 | 202 | 197 | 1 | 50 | 11 | 205 |
| matrix/lendw | 360 | 300 | 12 | 12 | 0 | 0 | 0 | 12 |
| hdr (header-paths branch) | 67 | 0* | 67 | 0* | 0* | 0 | 0 | 0* |
| probes (7 reviews) | 563 | 268 | 183 | 42 | 19 | 65 | 12 | 51 |
| **all** | 9,900 | 8,259 | 483 | 265 | 21 | 118 | 24 | 282 |

\* Every `hdr.` cell shares a prelude that declares `struct H { w: !W }`, so rule 1 rejects all of them. Counting only rule 1 hits on uses, rules 1+2 reject 23 of the 67, and rule 3 (and 3p) rejects all 67.

**No change:** examples/ (9), std/ (no std module hits any rule), and the README, WELCOME, STD, CORE, SYNTAX, DESIGN, FAQ, BEYOND-RUST and INTERNALS examples.

**What rule 3 rejects beyond rules 1+2**, by form and use (programs; a program may count twice):

- **Made leaves only: 244 programs.**

  | Use | Programs |
  |---|---|
  | `<(!a if c else !b)` moved | 65 + 9 |
  | `match (!a if c else !b)` and siblings | 47 |
  | lend of a part (`!(…).x`, `?(…).v`) | 46 |
  | assign through (`(…).x += 1`) | 31 |
  | receiver (`(!a if c else !b).keep(…)`) | 22 |
  | bind (`w = !a if c else !b`, `w = getw(!b) catch !a`) | 17 |
  | `as` | 12 |
  | `e!`, `e?`, `catch` over calls returning `!T`/`(!T)?` | ~30 of the above |

- **A place leaf (rule 3p): 21 programs.** These are `match`, lend, `for`, or move over `a if c else b`, `o ?? !d`, `o?`, with `a`/`b`/`o` held write views. Every one is a reviewer probe or a test of exactly that class, and all of them are the payload-loan/header bugs.

**Classes:**

- **(a) a test or probe of the form: all but one.**
  - The corpus (205) and the review probes are probes by construction. The largest groups are review-lend-base-2-gen (132), review-lend-base-3 (22) and review-step45 (13).
  - test/behavior has 12 tests that exist to exercise branches of write lends: `moved_branch_path_base`, `take_element_through_branch`, `take_through_branch_of_write_views`, `store_into_unnamed_receiver`, `match_made_write_view_lent_on`, `header_branch_points`, `lend_path_plain_forms`, `copies_coalesce_catch_views`, `repoint_local_forms`, `repoint_releases_old_view`, `write_view_result_binding_holds_view`, and `optional_view_from_branch` (also rule 4).
  - All 12 `lendw.` cells are the one binding kind `match_branch_lent_on`.
  - **SPEC L3525** is the "three forms are not this rule's" paragraph: `(!a if c else !b).x`, whose lends pick the place. Rule 3 makes it a `rig reject` example.
- **(b) real-style code: 1.** `test/behavior/emit/loop_label_shadow_value.rig`, a label test that happens to bind `k = if c … break :a !n else !m`.
- **(c) other: none.**

### Before/after rewrites

Each "after" passes `RIG_STUDY=enforce:1234 RIG_SANITIZE=1 rig run` with the original output. There is only one class (b) program, so the other four rewrites show what the most common class (a) forms become. The files are in `study-write-view-bindings/rewrites/`.

1. **loop_label_shadow_value (b).** A helper replaces the held branch:
   ```diff
   -  k = if c
   -    :a while true
   -      … break :a !n
   -  else
   -    !m
   -  k += 10
   +  if c
   +    :a while true
   +      … break :a
   +    bump(!n)        # sub bump(w: !Int)  w += 10
   +  else
   +    bump(!m)
   ```
2. **SPEC L3525**, an assignment through a branch:
   ```diff
   -  (!p if c else !q).x += 1
   +  if c
   +    p.x += 1
   +  else
   +    q.x += 1
   ```
3. **store_into_unnamed_receiver**, a branching receiver:
   ```diff
   -  (!a if c else !b).keep(?u)
   +  if c
   +    !a.keep(?u)
   +  else
   +    !b.keep(?u)
   ```
4. **optional_view_from_branch**, a `(!T)?` local (rules 3 and 4). The branch moves into a function's result, which both rules allow:
   ```diff
   -  w: (!Int)? = !x if x > 0 else none
   -  if <w as r
   +  pos = x > 0
   +  if only_if(!x, pos) as r      # fun only_if(m: !Int, c: Bool) -> (!Int)?  m if c else none
        r += 100
   ```
5. **A `(!T)!` result** (copies_coalesce_catch_views, `w = wget(!b) catch !a`). Literal rule 3 leaves no direct rewrite: `catch`, `!` and `?` over the call are all branches. The function must change to return `(!T)?` and be used through `if wget(!b) as w`, or the code that uses `w` must move into a helper called in each arm. Rule 3p allows the original.

## 2. Bug classes made unwritable

For each Critical/High finding: how many of its probes the rules themselves reject, whatever else main reports.

- A rule 1 or 2 hit counts only when it is on a use: a struct the grids' prelude declares but never uses does not count.
- Probes are the originals in `review-*-probes/`. The finding-to-probe map is in `study-write-view-bindings/groups.json`.
- For header-paths-1 (report now present):
  - **C1:** r06, r07, p08 and p09, plus every `grid2` and `grid1/g_for.meth_gvw` program main accepts.
  - **C2:** q03, q06–q10, p10 and p11.
  - **H1** is an oracle regression in the PR. The compiler rejects all its probes, so it is listed apart.

| Finding | Probes | Main accepts | 1+2 | 3 | 3p | 4 | 3+4 | 1+2+3+4 | Not reached by 1+2+3+4 |
|---|---|---|---|---|---|---|---|---|---|
| payload-loan-1 C1 | 13 | 0 | 13 | 0 | 0 | 0 | 0 | **13** | — |
| payload-loan-2 C1 | 7 | 0 | 7 | 0 | 0 | 0 | 0 | **7** | — |
| payload-loan-3 H1 | 5 | 5 | 5 | 0 | 0 | 5 | 5 | **5** | — |
| payload-loan-3 H2 | 6 | 6 | 3 | 0 | 0 | 3 | 3 | **6** | — |
| payload-loan-4 C1 | 12 | 0 | 8 | 12 | 12 | 1 | 12 | **12** | — |
| payload-loan-4 C2 | 5 | 0 | 0 | 5 | 5 | 2 | 5 | **5** | — |
| payload-loan-5 C1 | 16 | **16** | 9 | 16 | 16 | 0 | 16 | **16** | — |
| payload-loan-5 C2 | 5 | **5** | 1 | 5 | 5 | 2 | 5 | **5** | — |
| syntax-b-2 C2 | 12 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | all 12 (`match !x` payload loans: m01–m06, m09, m10, m13–m15, b02) |
| header-paths-1 C1 | 56 | **56** | 13 | 56 | 56 | 0 | 56 | **56** | — |
| header-paths-1 C2 | 8 | **8** | 1 | 8 | 8 | 0 | 8 | **8** | — |
| *header-paths-1 H1 (oracle)* | 5 | 0 | 1 | 0 | 0 | 0 | 0 | 1 | o01, o04, o05, o06 (compiler already rejects) |

- **Fully unwritable, of the 11 compiler findings:**

  | Rules | Findings |
  |---|---|
  | 1+2 | 3 |
  | 1+2+4 | 4 |
  | 1+2+3 (or 3p) | 9 |
  | 1+2+3+4 (or 3p+4) | **10** |

- **Probes unwritable, of 145:**

  | Rules | Probes |
  |---|---|
  | 1+2 | 60 (41%) |
  | 1+2+4 | 68 |
  | 1+2+3 | 130 |
  | 1+2+3+4 | **133 (92%)** |

- **Still open on main today:** payload-loan-5 C1/C2 and header-paths-1 C1/C2, 85 programs that main accepts. Rule 3 (and 3p) rejects all of them, and the unmerged `header-paths` PR does not close C1/C2.
- **What survives** is the `match !x` payload-binding loan (syntax-b-2 C2), which main now rejects by a fix. It is a held write view made by a header over a name, the third shape the previous study listed. A rule for it would be about `match !x` bindings, and it is not measured here.

## 3. Code that becomes deletable

Probe sites: programs reaching each site, and how many still reach it under each set of rules (accepted/rejected). A site is **dead** when no program left unhit by the rules reaches it. All 49 sites are in `study-write-view-bindings/sites.md`. The changes from rules 3 and 4:

| Site | What it is | main acc/rej | left 1+2 | left 1+2+3 | left 1+2+4 | left 1+2+3+4 |
|---|---|---|---|---|---|---|
| HC1 + TC09 + TC10 | `headerCopiesWriteView`, name leaf, and its `as` and `match` callers | 0/182 | 0/160 | **dead** | 0/97 | **dead** |
| HC2 | `headerCopiesWriteView`, field leaf | 0/139 | dead | dead | dead | dead |
| SM01b | `makesWriteView`: a branching subject of made leaves | 64/34 | 53/28 | **dead** | 53/28 | **dead** |
| TC18 | `matchReach`: `makesWriteView` gives `.written` | 98/101 | 55/51 | 12/23 | 55/51 | 12/23 (only `match getw(!e)` / `<w`) |
| SM01a, SM01c | `makesWriteView`: `!x` subject; call or `<w` subject | 233/243, 62/73 | still reached | | | |
| FA_rtw_value / FA_rtw_pointer | `Facts.readsThroughWrite`: the `as` binding's copy-out | 99/0, 145/0 | 8/0, 13/0 | 8/0, 11/0 | **dead** | **dead** |
| FA_payload_rtw, BA_match_wvfield_readown_write, OW01, OW_bare_wv_part, TC16 | payload read-through, write-view parts | | dead (rule 1) | dead | dead | dead |
| TC27 | clone of a value holding a write view | 0/5 | 0/1 | 0/1 | **dead** | **dead** |
| BA_as_copied_write | `if o as x` over a `(!T)?` binds `!T` | 23/94 | 12/47 | 7/9 | 2/8 | 2/4 (parameters) |
| TC_lendtemp_wv_branch_leaf | `lendTemp` rejecting a branch with a write-view leaf | 0/19 | 0/14 | 0/6 | 0/14 | 0/6 |
| `lendTarget`, `payload_view` (OW_lt_*, OW_pv_*), `bindingAccess` `.write` (BA_*), TC24/TC30/TC31, OW02, OW_reads_through_wv | | | still reached under every set of rules | | | |

**Deletable, with rough line counts (code plus doc comments):**

- **Rule 3, ~85 lines, about 55 of them on main today:**
  - `sema.headerCopiesWriteView` (~25);
  - `reportHeaderWriteViewCopy` (~20);
  - the `as` and `match` call sites (~10);
  - the branch walk in `readOnlyStep` (~10);
  - `makesWriteView`'s `yieldedLeaves` loop. It reduces to "`!x`, or a `!T`-typed call or `<w`" (~10).
  - `writeMatchAdvice`'s `.branches` hint (~6);
  - the structural-test entry (~2).
  - **The `header-paths` branch:** its whole path-through-a-branch decider (`c7e4294e`, `d8dc7a6e`) and the `hdr.` sigil dimension become unnecessary.
- **Rule 4, ~50 lines:**
  - `Facts.readsThroughWrite` and `ThroughWrite` (~25);
  - emit's two `as` copy-out sites (~20);
  - TC27's message (~4).
  - `payloadReadsThroughWrite` (~8) is already dead under rule 1.
- **Not deletable** under any set of rules: `lendTarget`, the `payload_view` machinery, `bindingAccess` `.write`, the `TC24`/`TC30`/`TC31` slot checks, `OW_reads_through_wv`, `TC13` (`if !o as x`), and the `lendTemp` branch check. They serve `match !x` / `if !o as x` / `for x in !v` bindings and `!T` parameters, which every rule keeps.

## 4. Matrix families

Cells main accepts, and how many each rule rejects (rule 1 counted on uses only).

| Family | Cells | Accepted on main | 1+2 | Rule 3 | Rule 3p | Rule 4 | 1+2+3+4 |
|---|---|---|---|---|---|---|---|
| `lendw.` | 1368 | 360 | 48 (60 with declarations) | 12 (`match_branch_lent_on`, all made leaves) | 0 | 0 | 60 by use, 72 (20%) with declarations |
| `hdr.` (header-paths branch; not on main) | 156 | 67 | 23 (67 with the prelude) | **67 (100%)** | **67** | 0 | 67 (100%) |
| `viewpay.` | 142 | 98 | 4 | 0 | 0 | 0 | 4 |
| `payload.` | 679 | 496 | 0 | 0 | 0 | 0 | 0 |

- No other family changes under rule 3 or 4.
- `hdr.` is the header-paths class. On main, 67 of its cells are accepted, and rule 3 rejects every one.

## Reproducing

- **Location:** everything is in `.git/revamp/r3/study-write-view-bindings/`.
  - `instrumentation.diff`: `src/study.zig`, the probes, and the `RIG_STUDY` switch.
  - The sweep: `run_all.sh`, `sweep.py`, `gen_matrix.py` and `extract_docs.sh`.
  - The analysis: `analyze.py`, `bugs.py`, `sites.py` and `findings2.py`.
  - The data: `results.jsonl.gz` and `r3forms.jsonl.gz`.
  - The verified rewrites: `rewrites/`.
- **Running it:**
  - Apply the diff to a7ac9080.
  - Copy the review probes to `study/probes/<review>/` and `header-paths:test/matrix.py` to `study/hdr/`.
  - Run `pup.sh <branch> 'bash study/run_all.sh "$CPUQ_CORES"'`, then `python3 analyze.py results.jsonl` (and `bugs.py`, `sites.py`).
- **Cleanup:** the pup worktree and the local branch and worktree were removed after the study.
