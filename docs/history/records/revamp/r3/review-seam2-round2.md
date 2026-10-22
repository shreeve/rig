# Review: seam2 round 2 (fixes ee6744f9, d723648b, 5ecbb669, c4b5e9f8)

Branch `seam2` at c4b5e9f8, rebuilt in /Users/shreeve/Data/Code/rig-seam2
(`zig build`, `zig build oracle`). New probes are in
`.git/revamp/r3/probes/review-seam2/r2/`. Each one ran under
`RIG_SANITIZE=1` and was compared with rig-v021. Oracle verdicts come
from `bin/rig-oracle -v`. The round-1 probes were rerun too
(`r2/round1-rerun.log`).

## Verdict: yes, there is a new soundness hole within seam 2's reach

**Answer to the question: yes.** At c4b5e9f8 the compiler accepts
programs that are unsound only because `!` now lends a temporary:

- `(!mkh()).r = ?mk(1).t`
- `wrap(!mkh()).r = ?mk(1).t`
- `(!mkh().me()).r = ?mk(1).t`
- `x = <(!mk(1) if c else !mk(2)).items`

Each runs into use of freed memory under the sanitizer, and rig-v021
rejected each one. Under AGENTS.md ("a feature that needs a second round
of soundness fixes stops for a redesign"), **the feature stops.**

To be precise about the cause: both holes are pre-existing classes that
seam 2 now reaches. Programs with no temporary hit the same bugs on
v0.2.1: `(!h).r = ?s.t`, `wrap(!h).r = ?s.t` and `<(!s if c else
!t).items`. They are siblings of round 1's C1 and C2 that the round-1
fixes did not cover:

- the C1 fix covers the call store path, but not the assignment store
  path;
- the C2 fix is syntactic, so it misses views that come from branches or
  calls.

A redesign should fix those two classes on main first. Seam 2 can then
be rebuilt on top of them.

## Findings

### Critical R2-1 (new instances from seam 2; class pre-existing): stores made by an assignment through a write target that is no named place are lost

Probes in `r2/`. New with seam 2 (v021 rejected each one):

| Probe | Statement | seam2 at c4b5e9f8 | Oracle |
|---|---|---|---|
| `z05_paren_lend_assign` | `(!mkh()).r = ?mk(1).t` | `dropS 1`, then `dropH sees` hits use of freed memory | abstains |
| `z01_assign_through_view` | `wrap(!mkh()).r = ?mk(1).t` | use of freed memory | **accepts** (oracle gap) |
| `z07_me_assign` | `(!mkh().me()).r = ?mk(1).t` | use of freed memory | **accepts** (oracle gap) |

`z14` (`(!mkh()).rs[0] = ?mk(1).t`) is the same construct; it only
stops early here because of an index-bounds panic on the empty Vec.

Pre-existing: each of these runs into use of freed memory on rig-v021,
on main, and on seam2.

| Probe | Statement | Oracle |
|---|---|---|
| `z11_paren_lend_assign_named` | `(!h).r = ?s.t`, with `s` in an inner block | abstains |
| `z16_paren_lend_elem_named` | `(!h).rs[0] = ?s.t` | abstains |
| `z02_assign_through_view_named` | `wrap(!h).r = ?s.t` | `DIFF` |
| `z10_elem_temp_assign` | `wv(!v)[0].r = ?s.t` | `DIFF` |

The holder's `drop` body reads the stored `String` after its Text is
freed.

**Root cause:** the C1 fix (ee6744f9) routes a call's stores through
the receiver's write loans. An assignment `T.f = v` whose target root
is a lend `(!e)` or a call that returns a write view does not record
`v`'s loans on what that view reaches. Only a target that resolves to a
named var's place does.

Sites that do record correctly:

- `swap`/`replace` into a temporary (`z04`);
- an argument that is part of a temporary (`z13`);
- a parameter view (`z09`).

**The class:** any write of a view into storage reached through a write
loan must be absorbed through that loan, whatever the target's syntax.
That includes call receivers, arguments, and assignment and compound
assignment targets. Round 1 named only receivers; the assignment path is
a sibling site.

### Critical R2-2 (new instance from seam 2; class pre-existing): the move-through-a-view check is syntactic

| Probe | Statement | seam2 at c4b5e9f8 | rig-v021 | Oracle |
|---|---|---|---|---|
| `w15_branch_temp_lends` | `x = <(!mk(1) if c else !mk(2)).items` | use of freed memory | rejected | `DIFF` |
| `w05_coalesce2` | `<(!s if c else !t).items` | use of freed memory | use of freed memory | `DIFF` |
| `w16_branch_read_lends` | `<(?s if c else ?t).items` | use of freed memory | use of freed memory | `DIFF` |
| `w18_wrap_call` | `<wrap(!s).items` (a write view returned by a call) | use of freed memory | use of freed memory | `DIFF` |

w15 is new with seam 2; w05, w16 and w18 are pre-existing.

**Root cause:** `lendOnPath` (d723648b) recognizes a lend only when a
`read` or `write` node sits directly on the member or index path. A
view that comes from a branch or from a call is a view by type, but no
lend node marks it. This breaks the rule "one classifier per fact":
whether a path passes through a view should be decided from the type of
each object on the path (`!S`, `?S`, `![]T`), not from its syntax.

The cases the fix does cover work:

- `<(!s).items` and `<(?mk()).items` are rejected;
- Box (`w06`, `w07`), handle (`w08`), element (`w09`), generic (`w10`)
  and nested-parentheses (`w13`) paths are rejected;
- taking an optional field through `!` works and leaves `none` (`w01`,
  `w14`); through `?` it is rejected (`w02`, `w03`).

### Medium R2-3 (pre-existing): `isConstant` misses some constants, and the emitted Zig fails to compile

| Probe | Statement | Result |
|---|---|---|
| `r2/kmod/main3.rig` | `inc(!Int.max)` | Zig: `expected '*i64', found '*const i64'` |
| `r2/kmod/main6.rig` | `setu(!U8.max)` | Zig compile error |
| `r2/kmod/main2.rig` | `setc(!lib.Color.red)` (enum of another module) | Zig compile error |

These behave the same on rig-v021. `namesUnitVariant` accepts only a
member whose object's symbol is a local nominal, generic or alias type.
It does not cover built-in number types (`.min`, `.max`) or a type
reached through a module.

What it does catch: `Color.red`, `E.bad`, `Shape.dot`, `"abc"`, `none`
and `5`. `lib.K` is rejected as a binding. Nothing that is not a
constant is classified as one: `!(x + 1)`, `!(-x)`, `!(f(1) + 2)` and a
payload constructor all run (`kmod/main5`, `main8`).

### Low

- **Stricter than round 1, and inconsistent.** `inc(!(5 if c else
  f(1)))` (`d01`) and `setb(!(not true))` (`e01b`) are now rejected as
  constants. Both ran correctly in round 1, because a temporary's slot
  takes the copy. Yet `inc(!(Int.max - 1))` (`kmod/main7`) is accepted
  and runs. This is a design choice, not a soundness issue.
- **Misleading note.** The note "`mkh()` still holds it after the
  statement" (`x02`–`x12`, `z13`) describes a holder temporary that is
  dropped after the viewed one within the same statement. The rejection
  is right; the note's reason is not.
- **Oracle gap.** The oracle accepts `z01` and `z07`, so no oracle set
  would catch R2-1 in those forms.
- **Parse.** `!f(x)(y).g()` again keeps the sigil outside, as in
  v0.2.1, which is consistent with the L4 restore. `!a.b(x)(y).g()` is
  back to `(!a).b(x)(y).g()` (`r2/f00_forms_r2.out`). No other parse
  form changed from round 1.

## Round-1 fixes verified

- **C1, store path through call receivers: verified.**
  - Round-1 probes h03, h05, h06, h07 and h08 are now rejected.
  - Rejected new forms:
    - generic-method calls with explicit type arguments, named (`x01`)
      and temporary (`x02`);
    - two stores in one call (`x03`), and the same through hoisted
      kwargs (`x04`);
    - a branching temporary receiver (`x05`) and branching named
      receivers (`x06`);
    - parts and elements of temporaries (`x08`, `x10`);
    - write views returned from temporaries (`x09`, `x11`, `x12`) and
      from named values (`x13`, `x16`);
    - a named Vec element (`x15`);
    - generic receivers and generic bodies (`y03`–`y06`; `y04` and
      `y06` run when the store does not outlive).
  - `x07` (`!(mkhopt(1)?).keep(?mk(1).t)`) is accepted, and the oracle
    agrees.
  - A safe order, with the viewed temporary made first
    (`put(?mk(1).t, !mkh())`, `x14`), is accepted and runs clean.
  - Callable views cannot be stored, and Cell cannot hold views, so
    those paths are closed by type.
- **C2: verified for member and index paths**, as listed under R2-2.
- **M1: verified for the round-1 cases** (`e04`, `e06`, `e07`); see
  R2-3 for the misses.
- **L1 hints: verified.** The `for` source hint (`k01`) and the
  optional-chain hint (`n03`) now explain that the `!` does not reach
  the receiver.
- **Seam 2's escape probes from round 1 are all still rejected**
  (`r2/round1-rerun.log`). All accepted round-1 probes still run
  sanitizer-clean with the same output.
