# Review: seam2-hotfixes, the v0.2.2 candidate

Branch `seam2-hotfixes` at b20a906a, rebased on main 0544af8a (v0.2.1).
It was rebuilt in /Users/shreeve/Data/Code/rig-seam2-hf (`zig build`,
`zig build oracle`). Probes are in
`.git/revamp/r3/probes/review-v022/`:

- `run.sh` runs a probe under `RIG_SANITIZE=1` with this branch and
  with rig-v021;
- `regress.py` and `recheck.py` do the regression run.

Oracle verdicts come from the branch's `bin/rig-oracle -v`.

## Verdict: no soundness finding, release can proceed

Each fix closes its class in every form I tried. Every round-1 and
round-2 probe that applies to main is now rejected, and so is every new
store and move form I wrote. No sound program in test/behavior or
examples changed. The remaining findings are pre-existing, and none of
them corrupts memory.

## Findings

### Medium 1 (pre-existing; a sibling of the constant class): a function name lent to write emits Zig that does not compile

| Probe | Statement | Zig error |
|---|---|---|
| `kmod/c03_fn.rig` | `setf(!f)` | `expected '**const fn (i64) i64', found '*const fn (i64) i64'` |
| `kmod/c10_fn_forms.rig` | `setf(!lib.twice)` | same |
| `kmod/c11_fn_method.rig` | `setp(!P.origin)` | `cast discards const qualifier` |

Here `sub setf(g: !fun(Int) -> Int)` takes a write view of a function.
rig-v021 behaves the same. The oracle abstains ("a write lend of a made
value").

A function declaration is a constant, just as an enum variant is.
`isConstant` excludes function-valued members on purpose
(`namesTypeConstant`), and it leaves bare names to `requireBinding`,
which flags only `const` and module bindings, not functions.

`g = f`, then `setf(!g)`, runs correctly (`kmod/c12`).

**Fix:** treat a name or member that resolves to a function declaration
as a constant.

### Medium 2 (pre-existing; unrelated to these fixes): assigning a closure through a `!fun` parameter is an internal error

`kmod/c13_fn_assign_closure.rig`:

```rig
sub setf(g: !fun(Int) -> Int)
  g = |n| n + 100
```

It fails with "internal error: cannot emit this expression (sema should
have rejected it)". rig-v021 behaves the same. It breaks "accept means
correct", but nothing reaches it through these fixes.

### Low

- **Oracle gap, pre-existing.** For `<(!s if c else !t).o` (`m16`,
  `m11`), the oracle reports `DIFF`, "C7 nothing is taken out through a
  read view". The compiler is right: it emits
  `rig.takeOut(&@as(*S, if (c) &s else &t).o)`, takes from the chosen
  branch, runs sanitizer-clean, and rig-v021 matches. The oracle models
  a branch of write lends as a read view. Adding this program to a test
  set would fail the oracle set.
- **SPEC overstates.** The new sentence "An optional is taken there"
  applies only through a write view. Through `?T` the take is rejected
  (`r2/w02`), and through `*T` it is too (`m17`).
- **Message.** `<(?h).items` on a handle `h: *S` is reported as
  "reached through `?h`, a view" (`m07`) rather than through a handle.
  It is still rejected.
- **Conservative, as before.** Overwriting the field that held a view
  does not release the loan (`t03`). The named form `t04` is the same on
  rig-v021, so this is consistent, not a regression.

## Attack results

### `storeThroughLend` (0e44c503 plus the call-path commit)

**Rejected; each of these ran into use of freed memory, or was silently
dangling, on rig-v021:**

- field assignments (`s01`, `s02`, `s12`, `s13`, `s14b`, `s20`);
- element assignments (`s03`, `s04`);
- a branching target, including a case where only the outliving branch
  matters (`s19`, `s21`; `s21` also gets the drop-order diagnostic);
- a `defer` store (`s11`, which ran on v021);
- through an optional, `(pick(!h) ?? return).r` (`s28`);
- a write receiver made in place (`s05b`, which is h06);
- a write view held in a struct field, `(!c).hv.r` (`s27`).

**`s23` (a newly caught pre-existing bug):** `wc(!c).w = !k` on a
`!Int` field. rig-v021 emitted a repoint to `k` that left a dangling
pointer; the branch now rejects it, as the named form `s24` always was.

**Already rejected on both builds:**

- `replace` and `swap` (`s08`, `s09`);
- closure captures (`s10`);
- stores inside a callee through an unnamed path (`s15`, `s16b`);
- whole assignment through a `!T` local or parameter (`s17`, `s18`);
- `Vec[!H]` (`s26`);
- unwrapping with `?` (`s29`).

Push and insert through an unnamed path need `!` on main, and are
rejected as lending a temporary (`s05`, `s05c`, `s05d`, `s22`). A Cell
cannot hold views, and callable views cannot be stored, so those paths
are closed by type.

**Sound stores still accepted:** a view of a longer-lived `s` through
`wrap(!h).r`, `(!h).rs[0]`, `wrap(!h).keep` and `(!h.me()).r` runs
correctly (`t01`). The loan is tracked: a later `!s` is rejected while
`h` lives (`t02`); rig-v021 accepted that program.

### `viewOnPath` (e8e0fa87)

**Rejected:**

- branching lends (`m01`);
- a call that returns `!S` (`m02`);
- a slice returned by a call (`m13`);
- an optional view unwrapped with `?` (`m04`, a use of freed memory on
  v021);
- an alias of `!S` (`m05`);
- a Box lend (`m09`);
- a generic `<(!g).x` (`m10`);
- a handle: `<(?h).items` and `<h.items` (`m07`).

**Still accepted, and correct:**

- copies through a view: Int and String fields (`m12`);
- optional takes through a write view, including `wrap(!s).o` and
  branching ones (`m11`, `m16`, `r2/w01`, `r2/w14`).

**Unchanged:** owned temporaries and named Box paths keep their existing
diagnostics (`m06`, `m08`, `m14`).

No false rejection was found.

### `isConstant` (b20a906a)

**Now rejected:**

- `lib.Color.red`, `lib.LE.boom`, `lib.Byte.max`;
- `U8.max`, `Int.min`, `Float.max`;
- `Small.min` through an alias;
- `Int.max - 1`.

All of these failed to compile in Zig on v0.2.1 (`kmod/c01`, `c05`,
round-2 `kmod/main2`, `main3`, `main6`, `main7`).

**Not misclassified as constants:**

- `!x`, `!p.x`, `!arr[0]`, a payload variant held in a var (`kmod/c04`);
- `!(x + 1)`, `!(-x)` (round-2 `kmod/main5`).

**Unchanged:** `const` bindings and module constants are still rejected
by `requireBinding` (`c06`, `c01`). `!T.max` in a generic body is
rejected because `T` is a type (`c02`). `!"abc"[0]` is rejected because
a String is read-only (`c08`).

**Missed:** function names (Medium 1).

### Earlier probes

Every round-1 and round-2 probe that applies to main is now rejected
(`c08`, `c09`, `c14`–`c16`, `h06`, `e04`, `e06`, `z02`, `z10`, `z11`,
`z16`, `w05`, `w16`, `w18`, `kmod/main2`, `main3`, `main6`, `main7`).
The optional takes `w01` and `w14` still run.

## Regressions

`regress.py` ran all 877 programs in test/behavior and examples under
`RIG_SANITIZE=1` with rig-v021 and with this branch. 32 differed, and
all of them were expected-panic tests. After normalizing thread ids and
`__func_N` suffixes (`recheck.py`), there were **0 real differences**.

This agrees with the agent's `v022/equiv.log`: 8309 programs, and only
the 4 new reject tests differ.
