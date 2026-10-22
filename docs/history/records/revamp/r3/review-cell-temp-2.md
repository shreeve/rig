# Review round 2: cell-temp (1fb2acba, base main 5e551bc5)

Adversarial review of the round-1 fix: `keepsCellChange`,
`keepMadeLeaves`, the `readLeaf` slot for Cell-holding made leaves, and
emit's backstop. Probes are in `.git/revamp/r3/probes/review-cell-temp-2/`:

- `run.sh f.rig...` runs the branch's `check`, a `RIG_SANITIZE=1` debug
  run and a `--release` build and run, each diffed against the file's
  `# expect:` block, and then `rig-oracle -v`.
- `stmt/t.sh 'stmt'...` runs one statement on the branch and on main
  (`probes/review-cell-temp/bin-main`, whose `src/` is identical to
  5e551bc5). Its prelude is `stmt/pre.rig`.
- `grid/` holds the generated grid (`gen.py`, results files, below).

Every expected output was computed from the semantics, by `gen.py`'s
model or by hand, and every mismatch was checked by hand.

## Verdict

**A soundness hole remains, and accepted programs still fail. The
feature should stop for a redesign.**

1. **Critical C1 (pre-existing, and the branch widens it).** A Cell
   change made through a read view (`?T` parameter, `?self`) is
   undefined behaviour in the Zig the compiler emits. In `--release`
   this causes:
   - lost changes
   - a bus error (a write to read-only memory)
   - a double free that corrupts the heap

   It happens on macOS and on pup, and on main with named locals only
   (`z01`–`z04`, `z06`, `z07`). In `z07` a plain `?self` counter in a
   loop crashes in release on both machines.

   The branch newly accepts forms that hit it. In the Mac release grid,
   98 newly accepted programs print the wrong output, for example:
   - `look(?mk(5))` in a loop (`z05`), wrong on both machines
   - `(a if k else mk(5)).hit()` with a `drop` type (`z08`), where the
     slot's `drop` sees the header from before the push

   The branch's guarantee, that "a written Cell is never
   in storage Zig keeps for the expression", only covers *where the Cell
   lives*. It does not cover the `*const` pointer it is written through,
   which is the actual problem.
2. **High H1 (branch).** The emit backstop *is* reachable from accepted
   programs: 1164 grid programs and `b01`, `b02`, `b05`–`b08`.
   - The cause is the same mismatch as round 1's Critical:
     `keepMadeLeaves` and `readLeaf` slot the leaves `sema.valueLeaves`
     finds, but emit reaches a different node.
   - It turns 488 previously accepted grid programs into internal
     errors. 452 of them ran with exactly the right output on main.
   - These include programs that only read the Cell, such as
     `print((d if k else mkdf(6)!).c.get())` with a `drop` type.
3. **Medium M1 (branch, partly pre-existing).** `Cell[Vec]` members on a
   bare-Cell receiver never record the receiver's read. `push`, `pop`
   and `clear` through a named-leaf branch are newly accepted and fail
   with an internal error (243 grid programs, `b03`). `mk(5).get(0)`
   leaks on main and on the branch (98 grid programs, `l01`).

**Wrong output remains, in release only** (C1). I found **no silent
wrong output in debug**. Every accepted grid program
runs with exactly the expected output under `RIG_SANITIZE=1`, apart from
the internal errors and the pre-existing `get(i)` leak. Slots in loops,
untaken branches and early exits are sanitizer-clean.

I found **no accepted form that copies a Cell holder.**

The oracle never rejects what the compiler accepts. It abstains on every
branching Cell holder.

---

## Critical

### C1. A Cell change through a `*const` pointer is undefined behaviour in release builds (pre-existing; the branch widens it)

**Probes:** `z01`–`z08`.

Each was run on the Mac (aarch64) and on pup (x86_64), in debug with
`RIG_SANITIZE=1` and in release (`bin/rig build --release`). Every one
except z02 and z05, which main rejects, also reproduces with the main
checkout's own `bin/rig` (5e551bc5). On pup they were run through
`pup.sh main`, with main's compiler, and z05–z07 with the cell-temp
compiler as well. z07 is the plainest case: a counter object, the shape
of SPEC §10's own `Counter` example, crashes in release on both
machines.

| Probe | Form | Debug | Release, Mac | Release, pup |
|---|---|---|---|---|
| `z01_release_named_local_bus` | `v = V(c: Cell(build(i)))`, then `v.add(maybe(i - 1) ?? 9)` (a `?self` push) in a `for` | `1 2 3` | **Bus error** in `Vec.reserve` (`self.buf = realloc(...)`): the header is in read-only memory | `1 2 3` |
| `z03_release_stale_header_free` | as above, with `?? continue`; the push reallocates | `drop 0 / 5 / drop 5 / 9 / drop 9` | `4 / drop 4 / 8 / drop 8`: the result and the `drop` see the old header | same as Mac |
| `z04_release_double_free_alias` | z03, then `x = build(4)`, `y = build(4)`, push to each | `0 1 0 1` | `0 1 0 -6148914691236517206` | same as Mac |
| `z02_release_read_view_param` | `look(x: ?Cell[Vec[Int]])` pushes; `look(?(<b))` (accepted by the branch only) | `2` | `1` | — |
| `z05_release_lent_temp_loop` | `look(?mk(5))` in a loop (main rejects it; the branch accepts it) | `v 2 / v 2` | `v 1 / v 1` | `v 1 / v 1` |
| `z08_release_slot_drop_stale` (the grid's `V__AkM__call__stmt__hit`) | `(a if k else mk(5)).hit()`, a `?self` push, with a `drop` (main rejects it) | `drop 2005` | `drop 1005` | `drop 1005` |
| `z06_release_part_continue` | `mkwv(i).t.add(maybe(i - 1) ?? continue)` | `… 2 … 3` | `… 1 … 2` | same as Mac (main and branch) |
| `z07_release_counter_bus` | an ordinary counter: `k.hit()` (`?self`: `c.set(c.get() + 1)`, `log.push`) and `total(?k)` on a named local, in a loop with `?? continue` | `20 20 159` | **Bus error** in `Cell.set` | **Segmentation fault** in `Cell.set` (main and branch) |

In z04, `0xAAAA…` is freed memory. The stale header's `drop` frees a
buffer that `realloc` already freed, and `smp_allocator` then hands it
out twice. This is heap corruption in safe Rig, with only named locals.

**Root cause.** A read view of a Cell holder is emitted as a Zig `*const
T`, and every Cell change through it is `@constCast(&x.c).vecPush(...)`.
A `?self` method is `fn add(self: *const V, ...)`, and a `?T` parameter
is `x: *const T`. Zig's LLVM backend marks `*const` pointer parameters
`readonly` (visible in `-femit-llvm-ir`, for example
`Io.Writer.writeAll(..., ptr nonnull readonly ...)`). Writing through
`@constCast` of such a pointer is therefore undefined behaviour to the
optimizer, even when the pointee is a `var` or a slot.

Proof by edit: in the generated `__rig_main.zig` for z01 and z02,
changing only `self: *const V` / `x: *const rig.Cell(...)` to `*V` /
`*rig.Cell(...)` and dropping the `@constCast` makes ReleaseSafe print
the right values (`/tmp`-local experiment; see Commands).

**Why it matters for this branch.** Its premise is that a Cell change is
right once the Cell lives in mutable storage (a slot). That is necessary
but not sufficient. The pointer the change goes through must not be one
Zig treats as read-only. The branch newly accepts temporaries lent to
read and `?self` calls on temporaries, so it adds new programs to this
class:
- z05
- every release failure in the grid (below)
- `z08_release_slot_drop_stale`: `(a if k else mk(5)).hit()` with a `drop` type. The slot's `drop` sees `1005` (the header before the push) in release, against `2005` in debug.
- z02's `look(?(<b))`

The PR's statement "Every review probe and Cell behavior test, in debug
and in release: all as expected" holds only because no test pairs a
`?T` Cell change with control flow the optimizer exploits.

**Fix (class).** A view through which a Cell may change must be lowered
as a mutable pointer: `?self` and `?T` of a type that `holdsCellByValue`
(as Rust's `UnsafeCell` removes `readonly`/`noalias`). Every
`@constCast` must then be a no-op on a pointer that was mutable all
along.

Sibling sites:
- `?self` receivers
- `?T` parameters, including generic `?T` at a Cell instance
- callable views `?fun(?T)`
- closures capturing `|?x|`
- a `?T` stored in a struct field

The class is "a Cell written through a pointer Zig considers const".
Add a release-mode matrix family: Cell[Vec] push and len through `?T`
and `?self`, in loops with `continue`, `?? e` and `break`.

---

## High

### H1. The emit backstop is reached by accepted programs, including read-only ones that ran on main

**Probes:**
- `b01_bang_leaf_backstop`: `(a if k else mkf(6)!).c.set(77)`
- `b02_q_leaf_backstop`: `(mko(6)? if k else a).hit()`
- `b05_bang_leaf_read_regression`: `print((a if k else mkf(6)!).c.get())`. Main prints `1 6 7 0`.
- `b06_nested_all_made_subbranch`:
  - `(a if k else (mk(5) if j else mk(8))).c.set(77)`
  - `(a if k else (mko(-1) ?? mk(5))).hit()`
  - a read of a nested branch
- `b07_optional_branch_unwrap`: `(o if k else mko(5))?.hit()`, and the read-only `(o if k else mko(5))?.c.get()`, which main runs (`2 5`)
- `b08_part_of_bang_leaf_regression`: `(ww if k else mkwwf(5)!).t.hit()`, and a nested read. Main prints `1 4 8 3`.
- `stmt/t.sh '(d if k else (mkd(5) if j else mkd(8))).hit()'`, and `'print((d if k else mkdf(6)!).c.get())'` with `D`, which has a `drop`

Every one of them fails with:

```text
internal error: cannot emit a Cell held in storage Zig keeps for the expression (sema should have rejected it)
```

**Grid:** 1164 accepted single-op programs hit this error. That covers
all four shapes `bang`, `bangfail`, `q` and `qfail`, every type (`D` and
`WD` with `drop` included), and every operation, `get` included. Main
accepted 488 of them. 452 of those ran with exactly the expected output
on main (`grid/regress_main_results.txt`). The other 36 (`WD` with `me`,
`bumped` or `hit`) lost the change on main, so the branch turns a wrong
answer into an internal error there.

**Root cause.** This is a classifier that disagrees with emit, as in
round 1:

- **Recording.** `keepMadeLeaves` and `readLeaf` record `dropsTemp` on
  the leaves `sema.valueLeaves` returns. That function recurses through
  every branching form: nested `if`, `??`, `catch`, `e!`, `e?`.
- **Emitting.** `emitLeafPtr` descends only while
  `handsOver(e).kind == .branches`. A sub-branch whose every leaf is
  made (`mk(5) if j else mk(8)`, `mko(-1) ?? mk(5)`, `mkf(6)!`) hands
  over `.made`. So emit stops at that node, finds no `dropsTemp` on it,
  and hits the backstop (`emit.zig:4525`).
- **Optional operand.** `emitPayloadHolder` gets the whole branching
  operand of `?`/`!`/`??`/`catch` (`(o if k else mko(5))`). That operand
  is neither `hasStorage` nor `dropsTemp`, so it hits the backstop at
  `emit.zig:4549`. Before the backstop, main emitted it by value: a copy
  of `o`. That copy is why the change form is unsafe and why the read
  form worked.

The backstop does its job: nothing is silently wrong. But "accept means
correct" fails, and so does "one classifier per fact". Where a made leaf
lives is decided by two different traversals.

**Fix (class).**
- The slot facts and the emitter must walk one shared definition of
  "the leaves of a branching value". Either `emitLeafPtr` descends
  through every `isBranchingForm`, whatever `handsOver` says, or the
  checker records the slot on the node emit reaches.
- A branching operand of `?`, `!`, `??` or `catch` with a named leaf
  needs leaf-wise payload capture, or a rejection in sema.
- Add matrix shapes:
  - `A if k else (M if j else M)`
  - `A if k else (o ?? M)`
  - `A if k else mkf()!`
  - `(A if k else mko())?`
  - each with `get` (read-only) as well as the changes

---

## Medium

### M1. `Cell[Vec]` members on a bare-Cell receiver skip the receiver's read

`cellVecCall` (`typecheck.zig:7384`) never runs `readLeaf` or `recordUse`
on the receiver object. This has two effects:

- **Internal error.** A named leaf of a branching receiver has no
  recorded use, so emit stops with "a value whose use no context
  recorded":
  - `(x if k else mkcv(5)).push(2)` (`b03_bv_push_named_leaf`)
  - `.pop()`, `.clear()`, and `poke(!…)`

  These are newly accepted by the branch: 243 grid programs. The same
  form with `.get(0)` already failed this way on main (149 grid
  programs).
- **Leak.** A temporary receiver of `get(i)` is never slotted.
  `print(mk(5).get(0) ?? -1)` with `mk() -> Cell[Vec[Int]]` leaks its
  Vec, on main and on the branch: `l01_cellvec_get_temp_leak`, 98 grid
  programs. It also emits `@constCast(&mk(5)).vecGet(0)`, which is only
  read.

Fix: read the receiver once, as every other method call does.
`push`/`pop`/`clear` go through `keepsCellChange` as now; `get(i)` and
`.len` through `readLeaf`.

### M2. `poke(!((<a) if k else M))`: internal error (pre-existing)

`b04_write_lend_moved_leaf`. A write lend of a branching value with a
moved leaf fails with "a value whose use no context recorded", on main
too. The grid has 132 such programs, every type, shape `move`,
operation `poke`. This is outside the branch's change, but it is the
same accept-means-correct class.

---

## Low

1. **New over-rejection.**
   `print((a if k else (mkf(-1) catch mk(5))).c.get())` is accepted and
   correct on main. The branch rejects it: "a view of the temporary
   `mk(5)` outlives its statement". The new `readLeaf` slot for no-drop
   Cell holders makes `N` behave like a drop type, and drop types are
   already rejected there on main (`stmt/t.sh`, case 5 vs case 7).
2. **Over-rejections, all safe.**
   - Reading the named leaf in an argument of a change through the same
     branch, `(a if k else mk(5)).c.set(a.c.get() + 1)`, is rejected
     ("use of `a` while a write loan is live"). The same holds in
     closures, `f01` (first version) and `b07`. `a.c.set(a.c.get() + 1)`
     is accepted.
   - `match mk(5).c.len` fails "this header binds a copy" for an Int
     (pre-existing).
   - `catch |e| (mk(5) if … else a)` fails "view outlives statement".
3. **The oracle abstains on every branching Cell holder.** Across the
   grid there are 15811 "unknown" function verdicts, with no
   accept/reject difference. So the oracle gives no independent check
   of exactly the forms this branch adds. The 0-differences result says
   nothing about them.

---

## Grid

`grid/gen.py` generates one program per (type × shape × made kind ×
position × operation). It computes the expected output from a model of
the semantics, including `drop` prints in order and headers dropping
their temporaries before the body.

**Axes:**
- **Types (11):**
  - `D` (a `drop`)
  - `N` (constant fields)
  - `P` (runtime `[16]Int`)
  - `G` (a `Text`; glue, no `drop`)
  - `W` and `WD` (the Cell in a part)
  - `V` (`Cell[Vec]` with a `drop`)
  - `B` (a bare `Cell[Int]`)
  - `BV` (a bare `Cell[Vec]`)
  - `VO` (`Cell[Vec[Text]]`)
  - `GEN` (`Gn[Int]` holding `Cell[T]`)
- **Shapes (22):**
  - a temporary, and a part of one
  - `A if k else M`, `M if k else A`, `M if k else M`
  - `o ?? M`, `mko() ?? A`
  - `mkf() catch A`, `mkf() catch M`
  - two nested branches
  - parts: of a branch, a leaf, `mkww().t`
  - `<a`, `(<a) if k else M`, `+a`
  - `A if k else mkf()!`, `mkf()! if k else A` (fails)
  - `mko()? if k else A`, `A if k else mko()?` (fails)
  - `mkf()!`
- **Made kinds:** constant constructor, or call.
- **Positions (9):**
  - statement, argument, `return`
  - headers: `if`, `while` (two evaluations), `match`, `for`
  - `defer`, loop body
- **Operations:**
  - `set`, `replace`, `get`
  - `?self` `hit`, `bumped`, and `me().c.get()`
  - `!self` `bumpw`
  - `look(?X)`, `poke(!X)`
  - `push`, `pop`, `clear`, `c[0] = 9`, `len`, `get(0)`

| Stage | Count |
|---|---|
| Programs generated | 22890 |
| Rejected by `rig check` | 8103 (grouped by message in `grid/rej_files.txt` / `chk_rc.txt`; all safe rejections: named-leaf lends, unique clone, move in a loop, `defer` jumps, …) |
| Accepted | 14787 |
| Oracle: accept/reject differences | **0** (`grid/all_orc.txt`) |
| Debug, `RIG_SANITIZE=1`, exact output | 13001 pass |
| Debug: emit backstop (H1) | 1164 |
| Debug: "use no context" (M1, M2) | 524 |
| Debug: leak (M1, `get(i)`, pre-existing) | 98 |
| Debug: wrong output, crash, use-after-free | **0** |
| Release, Mac (2791 combined programs of the 13001) | 2625 exact; **166 wrong output** (rc 0): `V` 134, `VO` 14, `BV` 18. Rerun op by op (`grid/results_single_release.txt`), 124 single programs are wrong in release: `?self` `hit`/`me` on `V` (Cell[Vec] with `drop`), and `look(?X)` on `V`/`BV`. In each, the change is lost or the `drop` sees the header before the push (C1). Main accepts 26 of them; **98 are newly accepted by the branch.** Debug was exact for every one. |
| pup (x86_64), the same 2791 | **Debug** (the self-hosted x86_64 backend) for the first 1370: all exact. **Release** for all 2791: 2625 exact, and **166 wrong output**. These are exactly the same 166 programs as on the Mac (`grid/results_pup_both.txt`, `grid/results_pup_release.txt`). |

`grid/results_single_debug.txt` has one line per failing single program.
`grid/failing_main.txt` gives main's verdict on each.

---

## Hand probes (all as expected unless listed above)

| Probe | What it checks | Result |
|---|---|---|
| `a01_array_index_branch` | `(arr if k else mka())[0].hit()`, set, replace, a hoisted index | debug and release ok |
| `a02_for_over_branch`, `a03_if_as_branch` | `for` / `if … as` over a named-leaf branch | rejected (header rules) |
| `f01_exit_after_slot` | `continue`, `break`, `return`, `!`, `?` in an argument after a branch's made leaf is slotted, in `for` and `while` | every value dropped once; debug and release ok |
| `h01_hoisted_args` | `?mk()`, `?mkwv().t`, and an all-made branch lent with a hoisted second argument that prints, fails or jumps | debug ok. Release differs only on `mkwv(i).t.add(… ?? continue)`, which is C1 (`z06_release_part_continue`, also on main) |
| `o01_cell_of_drop_owner` | `Cell[In]` where `In` has a `drop`: set, replace, `?self` and lends through temporaries, branches and loop bindings | every `In` dropped once, in order; debug and release ok |
| `p01_by_value_param` | a by-value parameter's Cell changed, with a constant constructor argument | ok |
| `g01_generic_holder_callback` | `Hold[T]` with `?self` calling `?sub(?T)`, on temporaries and branches | ok |
| `c01_module_constant_cell` | a Cell in a module constant | rejected |
| `stmt/` cases | escapes (`v = (a if k else mk(5)).me()` rejected), closures (`\|<e\|` owning the named leaf), generic `?self` `reset` on `Gn[Int]`, enum `?self` methods on payload Cells, moved fields | ok or rejected |

**Unique values.** None of these forms copies a Cell holder; each is
rejected or reached in place:
- `x = (v if k else mkv(5)).c`
- `w = (v if k else mkv(5))`
- `[(v if k else …)][0]`
- `+(…)`
- `(<w.t)`

`(v if k else mkv(5)).c.replace(Vec())` is accepted and correct.

---

## Commands

```bash
P=.git/revamp/r3/probes/review-cell-temp-2
$P/run.sh $P/z04_release_double_free_alias.rig      # release: 0 1 0 -6148914691236517206
bin/rig build --release -o /tmp/z01 $P/z01_release_named_local_bus.rig && /tmp/z01   # main checkout: Bus error
$P/run.sh $P/z05_release_lent_temp_loop.rig         # newly accepted; release v 1
$P/run.sh $P/b05_bang_leaf_read_regression.rig      # internal error; main prints 1 6 7 0
$P/run.sh $P/b03_bv_push_named_leaf.rig $P/l01_cellvec_get_temp_leak.rig
$P/stmt/t.sh 'print((d if k else mkdf(6)!).c.get())'
# C1 proof by edit: in ~/.cache/rig/z01_release_named_local_bus-*/__rig_main.zig
# make `add(self: *V, ...)` and drop the @constCast; zig build-exe -O ReleaseSafe prints 1 2 3.
# Grid:
cd $P/grid && python3 gen.py single && ../../../heavy.sh ./check.sh
python3 gen.py multi && MD=multi ../../../heavy.sh ./run_all.sh debug results_debug.txt
../../../heavy.sh ./srun_all.sh              # failing groups, op by op
MD=multi2 ../../../heavy.sh ./run_all.sh release results_release_mac.txt
pup.sh cell-temp 'cd ~/Data/Code/rig-wt/.review-cell-temp-2 && B=$HOME/Data/Code/rig-wt/cell-temp/bin MD=multi2 ./run_all.sh both results_pup.txt'
```
