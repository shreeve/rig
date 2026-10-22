# Review: cell-temp (09cc3e04, `git diff 81c75010...cell-temp`)

Adversarial review of "Change a temporary's Cell by a Cell method, in its
statement's slot". Probes: `.git/revamp/r3/probes/review-cell-temp/`
(`run.sh f.rig...` runs main's check, the branch's check, a
`RIG_SANITIZE=1` run diffed against the file's `# expect:` block, and
`rig-oracle -v`; `grid/` holds a 200-program generated grid, `grid/gen.py`,
`grid/one.sh`, `grid/results.tsv`). `bin-main/` holds main's `rig` and
`rig-oracle` (81c75010; the `src/` is identical to 5e551bc5).

## Verdict

**A soundness hole remains.** The branch's new forms let a Cell change
write constant memory (Critical 1). Accepted programs crash with a bus
error in debug on macOS and give wrong output in `--release` on both
macOS and pup (Linux x86_64). Everything else I probed in the PR's own
scope runs sanitizer-clean and prints what the source says: slot
temporaries, headers, loops, failure paths, escapes, generics, and Cells
of owners.

The oracle doesn't catch Critical 1. It abstains on every branching
value that holds a Cell (179 abstentions across the probes and the
grid).

There is no new compiler-accepts / oracle-rejects difference caused by
the branch's semantics. The six DIFFs I found are one oracle false
positive that already exists on main (Medium 3). The branch makes it
reachable at Cell types.

---

## Critical

### 1. A named-leaf branching receiver writes the made leaf through a const pointer (bus error / silent miscompile)

The PR accepts `(a if c else made()).hits.set(4)` "because the call
reaches the leaf it takes". The whole-receiver `?self` form and every
Cell method now take the same path. When the leaf taken is the *made*
one and its type has no drop glue, nothing keeps it in the statement's
slot:
- `requireCellPlace` returns `true` without recording anything when
  `namedLeaf(place.base) != null`.
- The `?self` receiver check does the same.
- `lendTemp` is never called on the made leaves.

So `storage.reachesLeaf` → `emitLeafPtr` emits the made leaf as a Zig
temporary, `&@as(T, expr)`, which is a const pointer. The Cell method
then writes through `@constCast`. For a constructor with compile-time
fields this pointer is into read-only data:

```zig
@constCast(&(if (k) &a else &@as(C, C{ .c = rig.Cell(i64){ .value = 2 } })).c).set(5);
```

| Probe | Form | Mac debug (`RIG_SANITIZE=1`) | Release |
|---|---|---|---|
| `k08_if_const_leaf_set.rig` | `(a if k else C(c: Cell(2))).c.set(5)`, k false | Bus error, rc 134 | runs, write lost |
| `k06_coalesce_const_leaf_set.rig` | `(o ?? C(c: Cell(2))).c.set(5)`, o none | Bus error | runs, write lost |
| `k07_made_first_const_leaf_hit.rig` | `(C(c: Cell(7)) if k else a).hit()` | Bus error | — |
| `k12_part_leaf_const_set.rig` | `(w.inner if k else W(inner: C(c: Cell(4))).inner).c.set(6)` | Bus error | — |
| `k15_bare_cell_branch.rig` | `(x if k else Cell(4)).set(7)`, a bare Cell | Bus error | — |
| `k10_named_leaf_runtime_made_view.rig` | `(a if k else C(c: Cell(3), ...)).me().c.get()` | Bus error | **prints 3, expected 4** (Mac and pup) |
| `k04`, `k05` | combined forms | Bus error | |

On pup the debug build (the self-hosted x86_64 backend) prints the right
values. Its release build prints `3` for k10. So the bug is a crash on
macOS and a silent wrong answer in release everywhere.

**Grid** (`grid/`, run with `heavy.sh ./grid.sh`). The axes are:
- type: with drop, or without
- made leaf: constant constructor, call, part of a constant constructor, or part of a call
- shape: `A if k else M`, `M if k else A`, or `o ?? M`
- operation: `set`, `replace`, a `?self` `hit`, `me().c.get()`, or each branch lent
- which leaf is taken

Of 200 programs, 172 run correctly, 8 are rejected (the `?o ?? ?M` lend
spelling), and **20 crash**. All 20 have a type with no drop, a constant
made leaf (a constructor or a part of one), the made leaf taken, and an
operation of `set`, `replace`, `hit` or `me`. Main rejects every one of
the 20.

**Pre-existing part of the class.** On main a `?self` method on a *part*
of such a branch was already accepted and crashes the same way:
`k11_part_named_leaf_const_main.rig`,
`(w if k else W(inner: C(c: Cell(4)))).inner.hit()`, gives a bus error
with main's binary too. The branch widens this from that one form to
every Cell method and to the whole-receiver `?self` form.

**Runtime made leaves.** `(a if k else mkc(5)).hit()` and
`(mkf(5) catch a).hit()` (`k13`) run correctly. They still write through
`@constCast` into a Zig temporary (`&@as(C, mkc(5))`, or `|*v|` on an
rvalue), which Zig does not guarantee is mutable. The k10 release
miscompile shows the optimizer does take advantage of that.

**Root cause.** SPEC §10 (new text) says a temporary whose Cell changes
"is kept in its statement's slot … the change lands there". SPEC §7 says
"a receiver that branches lends each leaf where it is". For a made leaf,
"where it is" has to be mutable storage the statement owns, which is the
slot. The checker records neither `cell_temps` nor `dropsTemp` for the
made leaves of a named-leaf branch. The emitter falls back to a Zig
temporary, which is only safe when nothing writes through it. Drop-glue
types escape only because readLeaf already slots them.

**Fix (class).** When a branching base has a named leaf and its type
holds a Cell (`holdsCellByValue`), keep each made leaf in its slot. Do it
in both `requireCellPlace`'s named-leaf branch and the `?self` receiver
check, by calling `lendTemp` or `recordTempDrop` on each made leaf, as
the per-branch lend `?a if c else ?mk()` already does. That form
correctly emits `rig.keep(...)` (see `k04`'s `bump(...)` line).

Alternatively, make `emitLeafPtr` never hand out the address of a Zig
temporary for a leaf whose type `holdsCellByValue`. The sibling sites
are every `emitLeafPtr` arm:
- the `if` yield
- `??`
- `catch`, `e!`, `e?` (the `|*v|` capture of an rvalue)
- a part of a made leaf (`W(...).inner`)
- the pre-existing part receiver (`k11`)

Add the grid's "no drop × constant made leaf × named leaf" cells to
`test/matrix.py`. The PR's tests use only `D`, which has a `drop`, so
they cannot catch this.

---

## High

None beyond Critical 1.

## Medium

### 2. `c[i] = e` on a temporary's Cell: the rejection is not one line

`made().lines[0] = 4` is rejected (`i02`), and the SPEC justifies this
"as any assignment to a part of a temporary is". But the same write is
accepted, and runs correctly, in two other spellings (`i01`):
- through a `?self` method, `made().setfirst(4)`, whose body is
  `self.lines[0] = v`
- through a view a call returns, `peek(?made()).lines[0] = 5`

`push`, `pop` and `clear` on the same Cell are accepted. `c[i] = e` is a
Cell member (SPEC's own table lists it beside `get`), not an assignment
to a part of the temporary: the slot keeps the temporary and its `drop`
sees the change, exactly as for `push`. The rationale given ("the change
is lost") doesn't apply.

Recommendation: accept it like `push` (record `cell_temps` for the
`index` case too). Otherwise, state the rule as syntax ("a temporary is
never the target of `=`") rather than as a Cell rule, and say in SPEC
that the method and view spellings are the workaround.

### 3. Oracle false positive (pre-existing on main), now reachable at Cell types

`(opt(?b) ?? ?mkt(0)).n` gets prod=accept, ref=reject C5, "a loan of a
temporary outlives its statement". The right operand is a lent
temporary, and the result is read within the statement.
- Pre-existing: main's compiler and oracle give the same DIFF with no
  Cell at all (`x04_oracle_coalesce_plain.rig`,
  `x05_oracle_coalesce_named_left.rig`, `x02_...text.rig`).
- New Cell spellings the branch admits: `x01`
  (`(mkc(5).opt() ?? ?mkc(0)).c.get()`), `x03`, and `k03`.
- Every one runs sanitizer-clean, and the emitted Zig keeps both
  temporaries in slots until the statement ends. This is a ref-gap in
  the oracle's `??` lowering, not a compiler hole.

It is a hard-gate shape all the same: a prod-accepts difference can't be
allowlisted, so any test of this form fails `./test/run oracle`. Fix the
oracle's handling of a lent temporary as a `??` operand before such a
program lands in the suite.

## Low

4. **The move rejection is syntactic.** `(<c).push(1)` and
   `(<a).c.set(10)` are rejected (`place.base.isKind(.move)`). But
   `(<a if k else mkd(2)).c.set(10)` and
   `(<h if k else H(...)).d.c.set(20)` are accepted and run correctly
   (`m01`). Either both forms are fine (the slot owns the moved value) or
   neither is. Deciding by the base's syntax runs against "one classifier
   per fact" (AGENTS.md).
5. **The read and write lends of a branching receiver disagree.** A
   `?self` method on `(a if c else mk())` reaches the leaf and may change
   `a`'s Cell. `!(a if c else mk()).bumpw()` is rejected as "would be lent
   as a copy" (`k09`), and so is `?(a if c else mk())` as an argument.
   Once the receiver path reaches leaves, the same mechanism (with made
   leaves slotted, per Critical 1) could serve `?(…)` and `!(…)`. That
   would turn CORE §3's *planned* item into one rule: "a branching value
   is reached at its leaves; its made leaves live in the slot".
6. **The diagnostic says a name holds a part of a temporary.**
   `bump(?(mkh(12).e if c else mkh(14).d))` says "it may be `mkh(12).e`,
   a value a name holds" (`c03`). No name holds it. Rejecting is right,
   since it would copy a part of a temporary out, but `namedLeaf` is
   `hasStorage`, not "a name holds". The receiver spelling
   `(mkh(4).d if c else mkh(6).e).c.set(20)` is accepted and correct
   (`c01`).
7. **The `namedLeaf` gate in `lendTemp` misses `unique` types.** It is
   `typeHasDropGlue or holdsCellByValue`, which doesn't cover a type
   declared `unique` with no Cell. Ownership's copy check still rejects
   `?(a if c else mkr())` (`u03`), so this is defense in depth with two
   rules for one fact. `sema.isUnique` would be the single classifier.
8. **The new `cell_place` text is misleading.** "...or an element of a
   temporary's Cell cannot be changed" reads as if the Cell can't be
   changed. Only `c[i] = e` is meant. See Medium 2.
9. **SPEC §10 leaves out the named-leaf rule.** It describes slot-kept
   temporaries but not that a branching receiver with a named leaf
   changes the leaf in place (which the PR description states). Add it
   with the made-leaf-in-slot rule once Critical 1 is fixed.
10. **Parse oddity (not this branch).** `x = (match k` followed by
    indented arms is a parse error ("unexpected `0`"), while
    `x = <(match k` parses. So `(match …)` can't be a receiver base, and
    I couldn't probe match-valued receivers.

---

## Checked and sound (sanitizer-clean, output as expected)

- **Escapes, all rejected with C5 and the oracle agreeing:**
  - a `?self` method returning a view kept past the statement (`e01`)
  - a view pushed into a `Vec[?D]` (`e03`)
  - a callee storing the view into a `!K` holder (`e04`)
  - a returned view (`e05`)
  - `r = ?mkd()` (`e08`)
  - `for` over a view from a lent temporary or a receiver (`e10`, `h05`)
  - `while … as` binding a view (`h07`)
  - `if … as` of an optional temporary: the header-copy rule (`e09`)
- **Views used within the statement:** chained `me()` calls (`e02`), and
  views held in a returned struct (`k03`). Receivers whose result holds
  a view are slotted, not block-local copies (`k02`, checked in release
  too).
- **`defer` and closures** (`e06`, `e07`).
- **Headers:**
  - `while ok(?mkd(n))`, `while mkd(m).hit()`, and
    `while mkd(k).c.replace(..)` are made, changed and dropped once per
    iteration (`h01`)
  - `for 0..count(?mkd())` and `for x in list(?mkd())` (`h02`)
  - `match`, a guard, `if` / `else if` (`h03`)
  - branching values in `while`, `for`, `match`, `if` headers (`h04`)
- **Branching values:**
  - named-leaf `if`, `??` and `catch`, with either leaf taken, for drop
    types (`b01`–`b03`)
  - nested branches; parts of temporaries in branches (`c01`)
  - arrays, Vecs, Boxes, optionals, `?`/`!` propagation (`c02`)
  - all-made constant branches (`k14`)
  - hoisted arguments with branching slot members: made once, no
    re-evaluation after the `@as` removal (`s01`, emit inspected)
- **Failure and jumps:** `!`, `?`, `catch break/continue/return` in an
  argument after the slot is filled, including a branching receiver.
  Each temporary is dropped once (`f01`, `f02`).
- **Cells of owners** (`Cell[Text]`, `Cell[Vec[Text]]`, `Cell[D]`):
  `set`, `replace`, `push`, `pop` and `clear` on temporaries, with no
  leak or double drop (`o01`).
- **Generics:** `G[T]` with `Cell[T]` at Int and at an owner, `peek[T]`
  of slot temporaries (`g01`). A generic body's named-leaf branch at a
  unique instance is rejected by the copies-T requirement (`u01`).
- **Receivers held by address** (the `emitAddressOf` change): `!` and
  `?` receivers on places, Vec elements, slot temporaries and branches,
  with hoisted arguments (`r01`).
- **Contexts:** `return`, a function's last value, a ternary arm, a
  binding, a constructor field, a closure, `push`, an array literal
  (`ctx01`).
- **Unique copies:** every named-leaf lend variant is rejected (`u02`).
  I found no accepted form that copies a Cell holder into a slot.
  Critical 1 is a *const-memory* problem, not a duplication.
- **Constant constructors** as slot temporaries and as whole and part
  receivers, debug and release (`k01`).
- **Signal:** it lives behind `*Signal` (`set` reaches it through the
  handle), so it is outside this change.

## Commands

```bash
P=.git/revamp/r3/probes/review-cell-temp
$P/run.sh $P/k08_if_const_leaf_set.rig       # Bus error, rc 134
bin/rig build --release -o /tmp/k10 $P/k10_named_leaf_runtime_made_view.rig && /tmp/k10   # prints 6508, 3 (expected 4)
RIG_SANITIZE=1 $P/bin-main/rig run $P/k11_part_named_leaf_const_main.rig                  # Bus error on main too
(cd $P/grid && ../../../heavy.sh ./grid.sh; grep CRASH results.tsv)                         # 20 cells
$P/bin-main/rig-oracle -v $P/x04_oracle_coalesce_plain.rig                                 # DIFF on main
```
