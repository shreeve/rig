# Review: `move-done` (1738234f, a82ee668) on main c169ec89

Reviewer: independent adversarial review. Probes are in
`.git/revamp/r3/probes/review-move-done/`, and `run.sh` there runs each
one: a check with main, a check with the branch, a branch run under
`RIG_SANITIZE=1` when the branch accepts, and `rig-oracle -v`.

Binaries:
- branch: `rig-move-done/bin/rig`, `bin/rig-oracle` (up to date with a82ee668);
- main: `probes/review-move-done/bin-main/rig-c169ec89`, built from
  `git archive c169ec89`.

**Note:** `/Users/shreeve/Data/Code/rig/bin/rig` is stale. It was built
at 17:59, before loop-lowering (#64) merged at 20:30, so it accepts
`test/reject/effects/while_step_*_condition_continue.rig` and
`review-loop-lowering-c01-*`. My first sweep used it and showed three
false differences. Every result below uses the fresh c169ec89 build.

## Verdict

**Soundness holes remain.** The branch fixes the `<(a if c else b).v`
hole it names, and three siblings it does not name (`??`, `catch`, and
an index of a branching value). But the `MoveSource.value` case still
accepts `<` forms that move an owner out of a made value while that
value's drop frees it. These forms reach the same rule through other
syntax:
- a `for x in <…` source;
- a leaf of `if`, `catch`, or `?`.

Each one is a use of freed memory under the sanitizer, and each is a
**compiler-accepts / oracle-rejects DIFF**, so the hard gate fails on
these probes. All of them are older than this branch (main crashes the
same way). But they are in the class the PR claims to close, "a `<`
source left usable / moved while something else drops it", through the
`for` carrier the PR says goes through `walkMove`. Under "fix the
class" they block the merge.

Separately, the rule the PR states ("`<` always leaves its source
done") still does not hold for branching values whose leaves copy, and
SPEC claims a rejection that the suite does not check.

---

## Critical

### C1. `for x in <mk().v`: use of freed memory, and an oracle DIFF

Probes:
- `p62_for_move_made_part.rig`: `for x in <mk().v`, `v: Vec[Int]`;
- `p63a`: `<(<a).v`;
- `p63b`: `<[<a, <b][0].v`;
- `p63c`: `<(mk() if c else mk()).v`;
- `p63d`: `<(+a).v`;
- `p63e`: `<mk().arr`, `arr: [2]Vec[Int]`.

```
cd .git/revamp/r3/probes/review-move-done
./run.sh p62_for_move_made_part.rig
```

- **Observed:** main and the branch both accept. The sanitized run fails
  with "Segmentation fault at address 0xaaaaaaaaaaaaaaaa" in
  `runtime.zig: it.vec.buf[it.next_index]` (rc 134), and p63c/p63e fail
  with "use of freed memory". The oracle reports `DIFF … h3 prod=accept
  ref=reject C3` (p62, p63b–e; p63a is unknown to the oracle).
- **Expected:** rejected, as `x = <mk().v` is ("cannot move a part out
  of the temporary `mk()`").
- **Root cause:** the emitted header
  `__rig_hdr: { var tmp: S …; defer rig.drop(&tmp); break (keep(&tmp, mk()).*).v }`
  drops the whole temporary, `v` included, and then iterates `v` and
  frees it again. In ownership, `walkMove(source, false)` classifies
  `mk().v` as `MoveSource.value`, a part of a made value "done with its
  statement", and only walks it. Whether an owning part may leave a
  temporary is decided in **typecheck** (`synthMove`: `tempBase` plus
  `needsCleanup`), and only for a `.move` node whose operand is a
  member or index. A `for` with `mode: move` has no `.move` node, so
  that check never runs. The existing corpus probe
  `final-review-a5e-for-take-made-items` covers only a Vec of *owning*
  elements (`Vec[Text]`), which a different typecheck rule rejects.

### C2. `<` of a branching value whose leaf is an owning part of a made value

Probes:
- `p64_branch_made_part_leaf.rig`: `<(mk().v if c else Vec[Int]())`,
  and `<(mk().v if c else <w)` as a function's value;
- `p66_catch_made_part_leaf.rig`: `<(get(true) catch mk().v)`;
- `p67_propagate_made_part.rig`: `x = <mk().o?`, `o: Vec[Int]?`.

- **Observed:** accepted on main and on the branch. Each is a use of
  freed memory under `RIG_SANITIZE=1`, freed in `dropFields` (rc 134).
  The oracle reports `DIFF … prod=accept ref=reject C2 "a bare
  mk().v owns a resource and would be copied"`.
- **Expected:** rejected. The same programs without `<`
  (`p65_bare_branch_made_part.rig`) are rejected: "bare use of `Vec`
  value `mk().v` … a field cannot be moved out of its parent".
- **Root cause:** `MoveSource.value` uses `movedTail`, which reports a
  nested leaf only through `ownsPlace`, and `ownsPlace` requires
  `resolvePlace`, so it covers only `.place`. A `.part_of_made` leaf
  that owns falls through. Typecheck's temporary-part check does not
  apply either, because the `<` operand is an `if`, a `catch`, or a
  `propagate_none`, not a member. `<` then turns off the bare-use check
  that would have caught it.

**Fix for C1 and C2: one class.** `MoveSource` should decide "a part of
a value made here" itself, with no help from typecheck:
- in `moveSource`, an operand whose `hands` is `.part_of_made` and whose
  type does not copy is a `part`, and is rejected;
- in `movedTail`, a nested `.part_of_made` leaf that owns is reported;
- the typecheck rule (`synthMove` → `tempBase`) moves into `MoveSource`
  (see M2), so the `for` header and every carrier get it.

Tests should cover `for x in <mk().v` with plain elements and each of
the leaf forms above.

---

## High

### H1. The rule's central claim fails for branching values whose leaves copy

Probes: `p46_branch_copy_leaf.rig`, `p47_propagate_copy.rig`.

```
n = 1; s = S(n: 2); o: Int? = 3
a = <(n if c else 5)          # n stays usable
b = <(s.n if c else 5)        # s.n stays as it was
d = <(o ?? n)
e = <(f(1) catch n)
g = <(s if c else S(n: 4))    # s: a plain struct
x = <o?                       # in fun f(o: Int?) -> Int?; `print(o)` afterwards works
y = <s.o?                     # s.o is NOT emptied: prints 4 afterwards
```

- **Observed:** all accepted by the branch, the oracle, and main. They
  run and print the sources unchanged (`… 1 2 3`).
- **Expected:** under "`<` always leaves its source done", each of these
  is a `<` whose source is left as it was. SPEC §7 Places (as edited by
  this branch) also says "`<(a if c else b)` and `<o?` are rejected, and
  written `<a if c else <b` and `(<o)?`". That holds only when a leaf
  owns, so the doc claim is not checked by the suite, against AGENTS.md
  rule 1. `<s.o?` is the most surprising case: a reader expects `<` on
  an optional field to empty it, and it neither empties the field nor
  is rejected.
- **Root cause:** `movedTail` reports a nested place only when it owns
  (`ownsPlace`). This is the same silent-copy early return the branch
  removed from `movePath`, kept here for branching values. The oracle
  shares the gap, so it cannot catch this class.
- **Fix:** in `movedTail`, report every nested `.place` leaf, whether
  it copies or not, with the existing "move it inside the branch:
  `<n`" or "take it before the `?`: `(<o)?`" wording. Run the survey
  again for the new rejections; there are probably none in the tree.

---

## Medium

### M1. A consuming method on a part that copies has no form, and the diagnostic advises one that fails

Probes: `p70_consume_receiver_copy.rig`, `p71_consume_receiver_copy_lt.rig`,
`p72_consume_receiver_workarounds.rig`.

```rig
struct P
  x: Int
  fun into(<self) -> Int
    self.x
struct S
  p: P
...
<s.p.into()      # main: accepted. branch: "cannot move out of `s.p`: it copies … drop the `<` to copy it"
s.p.into()       # both: "method `into` consumes the receiver; use `<receiver.into(...)`"
```

- Each of the two diagnostics prescribes the form the other rejects. The
  same happens for `<v[0].into()` on a `Vec[P]`.
- What works: `(+s.p).into()`, `P.into(s.p)`, or binding first
  (`q = s.p; <q.into()`).
- The PR's migration note ("Fix: drop the `<`") is wrong for this
  carrier, which the PR lists as covered (`move_part_that_copies.rig`
  line 96 tests only the rejection).
- **Root cause:** typecheck (`typecheck.zig:7674`, the `.place` arm)
  decides on its own that a consuming receiver needs `<`, without
  asking whether the receiver copies.
- **Fix, either of:**
  - accept `s.p.into()` when the receiver copies (it reads a copy, as
    `eat(s.p)` does);
  - make the part-copies diagnostic name `(+s.p).into()` for a receiver.
- Add a behavior test of the form that works.

### M2. "One classifier" is not yet true

The PR says: "No other pass decides it: the `walkList` dispatch and the
`for` header both call `walkMove`." But typecheck still decides, by its
own checks, whether `<` may take from a place:
- `synthMove` → `tempBase` + `needsCleanup`: "cannot move a part out of
  the temporary …". `MoveSource.value` silently depends on this, and C1
  is what happens when the dependency is missing.
- `requireAccess(.take)`: "cannot take out of a temporary", "… through a
  read view", "… through a shared handle", "cannot take constant". Here
  `MoveSource.optional_part` trusts the `takes` fact, which is recorded
  before access is checked.
- the consuming-receiver rule (M1).

The access checks are defensible as typecheck's job (writability), but
"may a part leave its made value" is the same fact `MoveSource` claims
to own, and should move into it. `movePath`, `takeable`, and the like
are gone. `takeableSubject` only builds a hint, and emit and storage
consume `takes` and names only, so neither decides on its own.

### M3. Kept cases: `<mk().n` is inconsistent with its siblings

Probes: `p40`, `p42`, `p43`, `p44`, `p45`, `p61`.

- `<mk().n` is accepted, a no-op copy. `<mk().o` (an optional) is
  rejected with "cannot take out of a temporary: nothing would see it
  emptied". The same reason applies to `<mk().n`: nothing would see it
  ended. `<mk().v` (an owner) is rejected, the one case where `<` would
  mean something. So `<` on a temporary's part is accepted exactly
  where it does nothing.
- `<mkh().n`, where `mkh` returns a `*S` made in the statement, is
  rejected ("it copies"), while the oracle accepts it: a **stricter**
  difference that `test/oracle/differences` does not list
  (`p42_kept_handle.rig`). Rejecting it is defensible, since the shared
  box outlives the statement, but it needs classifying.
- A drop body on the made value is sound for a part that copies
  (`p40_kept_drop_body.rig` runs clean: the drop runs, then the value
  is used). A write-view part of a made value is rejected for outliving
  its temporary (`p41`). A generic `<mk(<x).f` is caught per instance
  (`p45`).
- **Design suggestion:** reject `<` on any part of a made value that is
  not optional, with the part-copies message. Then the rule has one
  paragraph and no "made value" exception, and C1 and C2 close the same
  way. Survey: 0 programs.
- `<Color.red`, `<geo.Color.red`, `<"lit"`, `<(1 + 2)`, `<one`, and
  `<geo.mk` are accepted (`p44`, `p30_mod`). They are harmless, since a
  made value has no source to leave done. But `<one` (a function, which
  lives for the whole program) is accepted while `<K` (a constant,
  which also lives for the whole program) is rejected for living for
  the whole program. That needs one sentence or one rule.

---

## Low

- **L1. Fixed siblings without tests.** On main, these are also uses of
  freed memory, and the branch now rejects them correctly:
  - `<(o ?? b).v` (p03; on main it does not crash, since `o` is
    present);
  - `<(mk(true) catch b).v` (p04, main crashes);
  - `<(a if c else b)[0]` with `Vec[Vec[Int]]` (p06, main crashes);
  - nested parentheses (p05);
  - every carrier: `return`, argument, constructor, array, `match`,
    `for`, `break`, `*<`, receiver, `defer` (p50, all accepted on main).

  `move_part_of_branching_value.rig` covers only `if`. Add `??`,
  `catch`, an index, and a `for` source to it, and list them in the PR.
- **L2. Wording.** "drop the `<` to copy it": in Rig, *drop* means
  destroying a value (`-x`, "drop points"). Suggest "remove the `<`" or
  "write `s.n` to copy it". Otherwise the message is clear and accurate,
  including for `String` and `?T` parts.
- **L3. Misleading older messages.**
  - `<(a if c else b).o` says "cannot take out of a temporary"
    (`p07`), but it reads a binding.
  - `<h.w` with `w: !Int` says "`h` would still drop it"
    (`p80_write_view_field.rig`), but a write view is not dropped; the
    issue is its one holder.
  - "method `into` consumes the receiver; use `<receiver.into(...)`"
    for `h.d.into()`, where `d` owns, leads to a partial-move rejection
    (p54 first version).
- **L4. Aside, older, not this branch.**
  `print((?s).n, (!s).n)` is rejected while the oracle accepts it, an
  unlisted stricter difference (`p74_print_read_then_write_lend.rig`).

---

## Over-rejection sweep (item 3)

`sweep.sh` ran `rig check` with both binaries over every `.rig` under
`test/`, `examples/`, and `std/`, in main's tree (9276 files) and the
branch's (9278 files), through `heavy.sh`. Results are in
`sweep-{main,branch}-tree.{all,diff}`.

- **Main's tree:** exactly the survey's 11 programs change from
  accepted to rejected. Nothing else.
- **Branch's tree:** the 5 corpus probes (now marked as rejected) and
  the new `move_part_of_branching_value.rig`. Nothing else.
- **Docs:** no `rig` block uses `<` on a part that copies (checked by
  grep). The survey's count is confirmed.
- **Beyond the survey:** M1, the consuming receiver on a part that
  copies, which the tree does not use.

## Oracle (item 5)

`rig-oracle -v` ran on every probe:
- **DIFF (compiler accepts, oracle rejects):** p62, p63b, p63c, p63d,
  p63e (C1), p64 ×2, p66, p67 (C2). This is the hard gate.
- **stricter:** p42 (M3) and p74 (L4).
- Everything else agrees.

The oracle accepts the H1 forms too, so it shares that gap.

## What holds

- These are all rejected with accurate messages, and the oracle agrees:
  - views: `<(?s).v`, `<(!s).v`, `<get(!s).v`, `<rget(?s).v`, and
    `!S`/`?S` parameters (p10);
  - handles: `*T` and `~T`→`upgrade` parts (p20);
  - Cells (p21);
  - elements of `Vec[Vec[Int]]`, `Vec[S]`, arrays, and `![]S` slices
    (p22);
  - loop and `as` bindings (p53);
  - closures: `|?s| <s.n`, `*|<s| <s.v` (p51);
  - a `match` subject (p54);
  - module constants and their parts (p30_mod).
- Optional elements and fields holding owners are taken and emptied,
  and run sanitizer-clean: `Vec[Vec[Int]?]`, `[2]S?`, through `![]S?`,
  a dynamic index (p23), through a closure's `!s` capture (p52), and
  through a `!S` call result (p12).
- The advised fix ("drop the `<`") compiles and runs for every carrier
  but the receiver (p73).
