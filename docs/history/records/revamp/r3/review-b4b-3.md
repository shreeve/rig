# Review: B4b part 2, second round (6b00e981) and part 3 (61b7cf53, 800bd825)

Reviewer: independent fast-gate review, soundness and accept-means-correct only.
Tree reviewed: a detached worktree at 7366148a. It contains 61b7cf53, 800bd825 and 6b00e981, and the
commits after them (7366148a, c3558b2e) change only docs, so the code is the same as the branch head.
Built with `zig build` and `zig build oracle`.
Probes: `.git/revamp/r3/probes/review-b4b-3/`. `runq.sh <probe>...` prints one line per probe with
the branch check, main's check, the oracle, the `RIG_SANITIZE=1` debug run, and the `--release` run,
each under `timeout 20`. `run.sh` is the long form used in review-b4b-2.

## Verdicts

- **A (part 2 fixes, 6b00e981): no soundness hole found.** Both first-review findings are fixed
  (C1, the branching subject; H1, the guarded generic catch-all). No probe found a payload or
  catch-all view that outlives what it points at. Typecheck, the checker and emit all read the
  same in-place fact.
- **B (part 3, 61b7cf53 and 800bd825): no soundness hole found.** A bare `break x` moves exactly
  the names the checker says it does. Every path drops each value exactly once under the
  sanitizer. The new internal-error guard in `moveVar` did not fire on any of 18,511 files.

No Critical, High or Medium findings. The Low items below are over-rejections that main has too.

---

## A. Part 2 fixes (6b00e981)

### A.1 First-review probes, re-run (all 62 in review-b4b-2)

`../review-b4b-3/runq.sh p*.rig` from `probes/review-b4b-2`:
- **C1:** p63, p64, p65, p66, p67, p69 and p70 are all rejected now ("a `match` reads a place or
  takes a call's result; bind this `Opt[T]` to a name first"). p74 (a generic field of a branch)
  is rejected the same way, as main rejects it.
- **H1:** p78, p79, p80 and p81 are accepted, and emit now binds `const x = &o; saved = rig.lend(x);`.
  Before the fix it bound a copy. Debug and release both run clean and print the right values.
  p82 (`T = Counter`) is now accepted and runs: the catch-all is by address, so no copy forks the
  Cell, and the `no_cell` requirement is correctly skipped.
- Every other probe matches the first review's results: each probe the first review saw rejected
  is still rejected, and each one it saw accepted still runs sanitizer-clean, the same in debug and
  release.

### A.2 New probes (a01–a26)

| Probe | Shape | Result |
|---|---|---|
| a01, a02 | non-generic plain payload or catch-all (a copy) of a place, `?p` escapes, guarded and not | rejected "`p`/`x` does not live long enough" (correct: the binding is an arm-local copy) |
| a03 | generic, branching over lends `?o1 if c else ?o2`, then `o2` reassigned | rejected "cannot reassign `o2` while it is lent" |
| a03b | same, payload and catch-all views escape, guarded and not, Text and Int | accepted; clean, right values |
| a04, a24, a26 | Cell-holder catch-all or payload, guarded, generic and not; a24 sets through the escaped view | accepted; a24 prints 5, so the subject's own Cell changed |
| a05, a25 | generic guarded catch-all view escapes, then `o` reassigned (T = Text; T = Counter) | rejected (lent) |
| a06 / a06b | generic `match h.o` (field of a local), guarded; ok / then `h.o` reassigned | accepted, clean / rejected |
| a07 | generic `?Opt[T]` parameter, guarded, returns a payload or catch-all view | accepted; clean |
| a08 | generic `Box[Opt[T]]`, guarded catch-all | accepted; clean |
| a09 | generic `v[0]`, guarded catch-all view, then `!v.push` | rejected |
| a10 | non-generic plain enum branching over places (a copy), payload view escapes | rejected (arm-local) |
| a11 | generic `v[idx(?Text("a"))]` (header temporary), guarded and not | accepted; clean |
| a12 | generic nested match on a payload binding | rejected; over-rejection, see L1 |
| a13 | generic `if o as x`, view escapes, then `o` reassigned | rejected |
| a20 | generic guarded subjects `get(?h).o`, `getv(?v)[0]`, `hb.b` (Box field), and `p.o` through a view parameter, returned | accepted; all clean, right values, Text and Int |
| a21 / a22 | generic `*Opt[T]` handle, guarded payload view / then handle reassigned | accepted, clean / rejected |
| a23 | generic guarded catch-all of a `for` element, `break ?x` | rejected "`e` does not live long enough"; over-rejection, see L1 |

Every accepted A probe exits 0 under `RIG_SANITIZE=1` (debug) and `--release`, with the same output.
After a stack clobber (`clobber(n)`), every escaped view still prints the right value.

### A.3 One fact, read by every pass

- **Typecheck:** `arm_local = !storage.matchesInPlace(...)`. The catch-all `arm_view` flag reads
  `arm_local or !storage.catchAllByAddress(scrutinee, true)`, and `readBinding` skips the
  requirement for `!arm_local and catchAllByAddress(ty, true)`. The `true` passed there equals
  `!arm_local` for a read match, so it says the same thing as emit's `info.in_place`.
- **Emit:** `info.in_place = storage.matchesInPlace`. Unguarded matches use `emitCapture` →
  `catchAllByAddress(t, in_place)`. Guarded matches use `wholeBinding` → `catchAllByAddress(t,
  info.in_place)`. Payloads use `payloadByAddress(..., info.in_place)` on both paths. The old
  `wholeExpr` re-derivation (`writes or isPtrViewTy`) is gone. `grep` finds no other place that
  decides "by address" for a catch-all or payload.
- **Checker:** reads the `arm_view` flags that typecheck sets. For a payload, `readBinding(f.ty)`
  and emit's `payloadByAddress(binding=f.ty, ...)` agree: a view or slice returns early in both,
  and otherwise both test `copies == .depends` with `in_place`.
- **Instrumented check:** I built a throwaway compiler that prints when a read match has
  `matchesInPlace` true but `subjectHold` is not `.pointer`. This is the mismatch class behind C1.
  I ran `rig emit` with it over all 9,881 files in test/, examples/ and the review-b4b-2 and -3
  probes: **zero hits**. The instrumented source was reverted, and bin/rig was rebuilt clean.
- **Instance requirements stay in force for a consumed by-address binding:** `break x` or
  `return x` of a generic in-place payload or catch-all is rejected per instance ("copies a `T`";
  "`Counter` is unique") in b01, b03, b05. Non-generic, b04 is rejected "cannot move `x` out of
  `o`: `match o` reads".

---

## B. Part 3 (61b7cf53, 800bd825)

### B.1 Probes (b01–b48, c01)

| Probe | Shape | Result |
|---|---|---|
| b10 | `break :outer r` from an inner loop (labeled `while` and `for` as a function's tail), `break q` from a guarded match arm, from an `if … as` body, and a loop's `else` | accepted; each R dropped once, in the right order |
| b11 | outer-loop name broken bare by an unlabeled inner `break` | rejected "bare use … in `break`" (needs `<r`) |
| b12, b36 | broken on one path, used or dropped on others; two bare breaks and a `break <s` of different names | accepted; one drop per R (b36 checked over 4 instances) |
| b13 | `<r` on one path, then `break r` | rejected "use of `r` after move" |
| b14, b41 | loop-local `r` lent into an outer `?`/`!` holder, then `break r` | rejected "cannot move `r` while a read/write loan is live" |
| b15, b16, b34 | a closure capturing `r`; `break` inside a closure; `break` inside `defer` | rejected (capture of a local; parse error; "`break` is not inside a loop") |
| b17, b17b, b43 | `break h.r` (field), `break <h.r`, `break h` after `<h.s` | rejected (alias; "`h` would still drop") |
| b42 | optional field taken (`<h.r`), then `break h` | accepted; clean (drop 1 once, then 2) |
| b18, b39 | generic `break t` with T = Text, Int, Vec, `*R`, `Box[R]` | accepted; clean, handle counts right |
| b19 | a Cell holder and a `*R` (and a clone) broken bare | accepted; clean |
| b21 | `match <e` on a name declared outside the loop, payload broken | rejected "use of `e` after move" (oracle: stricter); over-rejection, see L2 |
| b22, b31, b32 | `if o as y` (a view), a view of a loop-local, a struct holding one, broken | rejected (type error; "`r` does not live long enough") |
| b23 | `defer -r`, then `break r` | rejected "a `defer` body cannot move or drop `r`" |
| b24 / b25 | owned closure from outside the loop / declared in it, broken bare | rejected (bare use of a handle) / accepted, clean single drop |
| b26 | `break a if c else b` (branching over loop-local names) | rejected (bare use); conservative |
| b30 | `while next(i) as r` (owned header binding), `break r if ...` | accepted; clean |
| b33 | loop value `R?`, `break r` lifted, `else none` | accepted; clean |
| b37, b44, b47 | `match <e` on a loop-local, payload `break p`, guarded and not; generic `for e in <xs` / `match <e` / `break v` | accepted; the other payload field dropped once; clean |
| b38 | fallible body: a call fails after a loop-local `r` is made, then `break r` | accepted; `r` dropped once on the failure path, moved on success |
| b40 | `Box[R]` broken from an inner `for` to a labeled outer `while` | accepted; clean |
| b45 | `maybe(i) ?? break r` and `check(i) catch break r` | accepted; clean |
| b46 | a loop inside a closure body, `break r` as the closure's value | accepted; clean |
| b48 | `break r` inside an `if mk(i).o as y` whose header holds a made value | accepted; the header temporary and `r` each dropped once |
| c01 | bare-name tails of every form `planConsumed` lists: fun, method, closure, `if`/`else`, `if … as`, `match`, loop `else`, `??`/`catch` | accepted; clean; no internal error |

All accepted B probes exit 0 under `RIG_SANITIZE=1` and `--release`, and the two modes print the
same output. I checked each output line by line against the drops each path should run.

### B.2 Why the consumed fact matches the checker's moves

Emit takes from a name (`rig.take`, which disarms its drop flag) only when two things hold: the
`consumed` fact records the name, so it has a flag, and the use is `.take`. The checker moves a
name in four places:
- `<x` → `.move`;
- `|<x|` → `.cap_move`;
- `return x` → `.return`;
- a bare name at a tail, through `consumeTailName` or `breakMovesName`.

The tail case is reached only from forms that `planConsumed` walks with the same
`sema.eachTailPart`: `return`, `break`, `for`, `if` with `else`, `??`, `catch`, `match`, `while`,
`raw_block`, `fun`, and a lambda that `lambdaYields`. So a checker move outside the fact cannot
come from these paths. I found none in practice.

The reverse can happen: the fact records a name, emit takes it, and the checker does not move it.
That would need a bare `break x` the checker accepts as a read. For an owning `x` declared outside
the loop, the checker rejects that ("bare use … in `break`", b11, b24). The excluded kinds are
`closure`, `loop_view`, `capture_resource` and `alias_of`. Of those, b25 (a closure declared in
the loop) is accepted: emit takes it and the scope ends, so it is dropped once.

### B.3 The internal-error guard in `moveVar`

I ran `rig check` over 18,511 files (test/, examples/, std/, and the break, review-b4a, -b4b-1,
-b4b-2, -b4b-3, review-loop-lowering and review-move-done probe sets). **No output contains
"internal error".** c01 also exercises every tail form and does not reach it.

---

## Over-rejection sweep against main

The same 18,511 files were checked with main's `bin/rig` and the branch's. **No file is rejected by
the branch and accepted by main.** 207 files are accepted by the branch and rejected by main (the
part 1–3 lifts plus my probes). I ran all 207 under `RIG_SANITIZE=1` (debug) and `--release`:
- 205 exit 0, with the same output in both modes, and 11 that have `# expect:` match it.
- 2 exit 134 in both modes. These are two copies of the same file: an old `for_source_through_temporary`
  test under `probes/review-b4a/` (`x20_…` and `work/rig-exp/…`). The program indexes an empty Vec
  (`m[idx(...)]` on an empty `m`), so this is a checked bounds panic in the program, not a
  soundness issue. Only the stack-trace paths differ between the two modes.

## Oracle

Every probe was run through `bin/rig-oracle`. There is no `DIFF prod=accept ref=reject`. It
reports "stricter" (prod rejects, the reference accepts) for:
- a12 (nested match on a payload binding);
- b21 (`match <e` on an outer name inside a loop that always breaks);
- the earlier p22, p24 and p25.

These are the Low items below.

## Low (over-rejection; main rejects these too; no soundness impact)

- **L1.** A view through a match on a binding is held to the binding's scope. This covers a nested
  `match x` on a payload binding (a12) and a `for e in v` element (a23, `break ?x`). It is the
  documented `match i` case (p24, p25).
- **L2.** b21: a `while true` whose body always breaks after `match <e` (with `e` outer) is rejected
  "use of `e` after move", because the checker assumes the loop can repeat. The oracle accepts it.

## Commands

```bash
cd .git/revamp/r3/probes/review-b4b-3
./runq.sh a*.rig b*.rig c*.rig
(cd ../review-b4b-2 && ../review-b4b-3/runq.sh p*.rig)
```

(The run scripts point at the removed worktree `scratchpad/b4b3-review`; recreate it with `git worktree add <path> c3558b2e`, build, and edit `W=` to re-run them.)
