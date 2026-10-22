# Review: seam2 (`!` lends any value to write), round 1

Branch `seam2` at 279f1dbd (5 commits on main 089169c1), built in
/Users/shreeve/Data/Code/rig-seam2. Probes are in
`.git/revamp/r3/probes/review-seam2/`. `run.sh` runs each one under
`RIG_SANITIZE=1` on the branch and checks it with rig-v021. Oracle
verdicts come from the branch's `bin/rig-oracle -v`.

## Verdict

**Not ready.** One new Critical finding: a temporary lent to write as a
method's receiver can be made to hold a view of a temporary that is
dropped before it. The branch's headline form, `!mk().m(...)`, reaches
the use of freed memory directly. The root cause is a pre-existing
hole: a store into a receiver that is not a named place is lost. The
branch makes that hole reachable through ordinary code. The oracle
already flags these programs as `DIFF` (compiler accepts, oracle
rejects); no oracle set contains one.

A second Critical finding is pre-existing: a move out of a part of a
parenthesized lend, `<(!s).items`. The branch extends it to temporaries.

Everything else the branch claims checks out.

## Findings

### Critical 1 (new instances of a pre-existing class): stores into a write receiver that is not a place are dropped

Probes: `h03_store_into_recv.rig`, `h05_store_read_view.rig`,
`h08_push_into_temp_field.rig` (new), and `h06_store_via_view_recv.rig`
(pre-existing). `h07_store_via_view_recv_bang.rig` is the `!` form of
h06.

```rig
struct H
  rs: Vec[String]
  sub keep(!self, r: String)
    !self.rs.push(r)
  drop(!self)
    print("dropH sees", self.rs)
...
sub main
  !mkh().keep(?mk(1).t)          # h05
  !mkh().rs.push(?mk(1).t)       # h08
```

Output on seam2: `dropS 1`, then `dropH sees ["error: rig: use of freed
memory`, a sanitizer trap. h03 has an `Int` field and prints poisoned
garbage instead: `dropH sees -6148914691236517206`. rig-v021 rejects
all three ("cannot lend a temporary to write").

The pre-existing sibling h06, `wrap(!h).keep(?s.t)` with `s` in an
inner block, runs and hits use of freed memory on rig-v021 and on main
too.

Oracle: `DIFF h03/h05/h07/h08 main prod=accept ref=reject C5`. For h06
the oracle abstains ("a write receiver without `!`").

The argument form of the same program, `put(!mkh(), !mk(1).at())`
(`h04`), is rejected correctly.

**Root cause:** `src/ownership.zig`, `walkCallBody`. The views a call
may store (`stored`) are absorbed into the receiver only through
`recv_root`, and `recv_root` is set only when the receiver resolves to
a var's place. A receiver that is a lent temporary (`(!mkh())`, through
`walkLend` → `lendTempToWrite`), a part of one (`!mkh().rs`), or a
write view made in place (`wrap(!h)`) leaves `recv_root` null. Only
`consumed_recv` and the arguments go through `absorbThroughWrites`, so
the store is never recorded on the holder.

The holder temporary is made before the viewed one, so
`dropStmtTemps` drops the viewed one first and the holder's `drop` body
reads it afterwards. `dropStmtTemps` would have reported this
(`holderLive` is true for hidden vars), but the holder's flow carries
no loan.

**Fix the class:** for a write receiver whose `recv_root` is null,
absorb `stored` through the write loans of `recv_value`
(`absorbThroughWrites(recv_value, …)`). That covers built-in receivers
(`push`) as well as user methods. Then add h03, h05, h06, h07 and h08
as reject tests or corpus probes.

### Critical 2 (pre-existing; the branch adds instances): `<(!x).f` and `<(?x).f` move a part out through a lend

Probes: `c08_move_part_named.rig`, `c09_move_part_read.rig`,
`c14_move_part_named_lent_plain.rig` and `c15_move_through_param.rig`
(all pre-existing: rig-v021 and main accept them and they fail at
runtime). `c04_move_part.rig` and `c12_move_elem.rig` are new reach.

```rig
sub steal(p: !S)
  x = <(!p).items      # c15: moves out of the caller's value through a write view
```

Output: `use of freed memory` in every probe. The emitted code is
`var x = (…).items; defer rig.drop(&x);` while the owner still drops
`items`.

The plain form `<s.items` is rejected ("partial moves are not
supported"), and so is `<mk(1).items`. The parenthesized lend bypasses
both checks.

On seam2, `x = <(!mk(1)).items` and `x = <(!mkv())[0]` are new
instances: v021 rejected them only because the temporary could not be
lent to write.

The oracle abstains on all of them ("a sigil on an accessed object").

**Root cause:** the move check classifies `(!p).items` as a path from
`p`, or from the temporary, without the partial-move and move-out-of-view
rules that `<p.items` gets. That is the classifier the
"one classifier per fact" rule asks for. This is not the branch's bug,
but the branch should not ship more reach into it. Either fix the class
here (a `<` whose operand path passes through a `read`/`write` node is
a move out of a view: reject it) or block it for the new temporary
forms.

### Medium 1 (pre-existing; sibling missed by the literal fix): `!Color.red` and `!E.bad` emit Zig that does not compile

Probes: `e04_enum_const.rig`, `e06_error_const.rig`.

```rig
setc(!Color.red)      # sub setc(c: !Color)
sete(!E.bad)          # sub sete(e: !E)
```

Output on seam2 and rig-v021: Zig fails with `expected type
'*__rig_main.Color', found '*const __rig_main.Color'`. That breaks
"accept means correct".

The branch fixes `setb(!false)` with a `base == .src` check
(`lendsToWrite`), but an enum variant or error value named through its
type is a constant of the same kind and is not a `.src` node.
Module-level constants (`inc(!K)`) are already rejected.

The oracle abstains ("a write lend of a literal").

**Root cause:** `lendsToWrite` identifies a constant by syntax (a bare
token) instead of by a positive fact. Use one classifier for "a
constant: a literal, an enum or error value, a module constant".

### Low 1: misleading "add `!`" hints when the `!` is already there

- `k01_for_view.rig`: `for x in !mk(1).vs()`. The `for` takes the
  `!` as its mode, and the error says "add `!`: `!mk(1).vs()`", which is
  the text the user already wrote.
- `n03_opt_chain.rig`: `!mkopt(n)?.pop()` keeps the sigil outside, as
  `!x?.m()` does for a name. The error starts "a temporary no name
  holds; add `!`" before giving the right form, `!(mkopt(n)?).pop()`
  (which runs: `n04`).

Both reject correctly; only the wording is wrong.

### Low 2: wrong reason for a branching enum constant

`e07_enum_branch.rig`: `setc(!(Color.red if c else Color.green))` says
"it may be `Color.red`, a value a name holds". `namedLeaf` treats a type
member as a name. The program is rightly rejected, but for the wrong
reason. Fixing Medium 1 with a positive constant classifier fixes this
too.

### Low 3 (pre-existing message): `inc(!(2 + 3))` and `inc(!-5)` say "expected `!Int`, got `!Int`"

`e01_literals.rig`, `e02_lit_int.rig`. v021 gave the same text for
`inc(!5)`; the branch now gives the literal message for `!5` and
`!(5)` but not for constant-folded expressions. `inc(!-f(1))` runs.

### Low 4: `!a.b(x)(y).g()` changes reach

`f00_forms.out`: before, `!a.b(x)(y).g()` was `(!a).b(x)(y).g()`; now
it is `(!(a.b(x)(y))).g()`. That happens because `isMethodCallee`
returns false for a call whose callee is a call, so the walk stops at
the outer call.

No accepted program changes meaning: `b` would need `!self`, and then
the new parse rejects it. Owned closures cannot return a type with a
`!self` method usable this way (`g02`). It is still inconsistent with
"`!` reaches the first method's receiver", so document it or make the
walk continue through a called callee.

## Claims verified

- **The rule.** Accepted, and runs sanitizer-clean with the right
  output and drop order:
  - receivers, results, parts and slices (`b01`, `q01`, `v01`);
  - nested temporaries `!mk(!mk(1).pop()).bump()` and
    `!wrap(!mk(5)).pop()` (`b01`);
  - hoisted kwargs, including a branching receiver (`b03`, `o02`);
  - `defer` (`a07`);
  - `!` and `catch` paths, with the temporary dropped on failure (`a09`,
    `a15`);
  - `?? continue` and `?? break` after the temporary is made (`i01`);
  - short-circuit and conditional temporaries (`u01`);
  - Box (`p01`);
  - Text through every receiver shape (`m01`, `m02`);
  - generic bodies (`t01`);
  - branching temporaries with `<s` branches, where the moved name is
    dropped only when not taken (`l01`), and with clones (`l03`).
- **Escapes rejected:**
  - write views held, stored or returned (`a03`, `a06`, `b02`, `c03`);
  - `!`, `?`, `??` and `catch` propagation (`a08`, `a10`, `a11`, `a13`);
  - `if … as` and `match` headers (`a12`, `a14`);
  - repointing a `!T` local or holder (`r01`–`r05`);
  - generic `T` holding a view (`a16`–`a18`);
  - closures (`a06`, `j01`, `j04`);
  - Cell (`j03`);
  - `for` over a temporary (`k02`).

  A generic `id(!mk(1).at())` with `T = Int` copies the value and
  holds no view (`a01b`: `var r: i64`).
- **Aliasing through a temporary that holds a write view of a name is
  caught** (`i02`–`i04`).
- **Still rejected:**
  - bare `mkv().push(1)`, with the hint;
  - `!mkh().bump()` and `!mkh().items.push(…)`;
  - `!false`, `!5`, `"abc"` and `none`;
  - branches that may be a name's;
  - `<self` and `?self` methods with `!` ("drop the `!`", `c02`, `c05`).
- **Parse change.** `test/equiv.py rig-v021 seam2` reports 8315
  programs, 53 differ: the same list as the agent's `equiv2.log`.
  Every program whose `parse` or `normalize` section differs (21, plus
  3 new doc blocks) is rejected by rig-v021, so no accepted program's
  meaning changed. The full table of forms is in `f00_forms.out`:
  - `!-x`, `!!x`, `!x?.m()`, `!f()?.m()`, `!(f(x).g())` and `!+s.g()`
    are unchanged;
  - `!f().g().h()` and `!(a if c else b).m()` now lend the head.
- **`write_place`:** branches of different Zig types (literal versus
  call, `comptime_int` versus `i64`, array literal versus call, Text
  constructor versus call) all run correctly (`d01`, `d02`). A
  `write_place` that leaks into nested arguments under a branching read
  value runs correctly (`o01`).

## Rounds

This is round 1. Critical 1 is a soundness fix the feature needs before
merging, and fixing its class also closes the pre-existing h06. If a
round 2 review finds another soundness hole in this feature, the
feature stops for a redesign, per AGENTS.md.
