# Review of PR #922 (rv-decisions)

Probes are in `$TMPDIR/r922/` (run.sh runs both rigs under RIG_SANITIZE=1). The
batteries are in `bat/` and `bat2/`, each with a `summary.txt`. The single areas
ownership-for and types-chains are green.

## 1. CRITICAL: a chain anywhere in a block turns off that block's scope-end lifetime check

This bug is already on main, but the PR widens it. It is the hole the U4
decision ("the result keeps its source lent") depends on.

- **Where:** `src/rig.zig:5189` (`synthLeaf`) puts each hidden chain leaf at
  `source.len + padded`, which is past the end of the file.
  `src/ownership.zig:8708` (`extent`) takes the maximum over a node's children.
  So `popScopeWith` (ownership.zig:1562) passes `end = ext.hi + 1`, also past
  the end of the file, to `releaseVarsFrom`. There `reportHolder` asks
  `holderLive(holder, end)`, which is false, so no
  "does not live long enough" error is reported.
- **Probes** (all accepted, then "use of freed memory" at run time; the oracle
  rejects each one with `C5 qs does not live long enough`):
  - `x1.rig`: the escape is a plain `best = ?qs[0]` in an inner block. An
    unrelated `print(xs.filter(|x| x > 1).count())` in the same block hides
    it. Main has the same bug. Without the chain, both rigs reject it.
  - `u2.rig` and `b3c.rig`: `best = ?qs.filter(f).collect()` over a
    `List[P]`, escaping the inner block. **This is new in the PR**: main
    rejected collecting views of objects.
  - `u3`, `u4`, `u5`, `u8`, `b3`: the same escape through `find`, `max_by`,
    or a `collect` of Strings. Main has these too.
- **Fix:** make `extent` skip padded leaves (`pos > source.len`, or map them
  through `pad_homes`), or take a scope's end from its parser span. Add `x1`
  and `u2` as `fail` cases. Land this before, or with, the change that
  accepts object `collect`.

## 2. LOW: the loop-view rule now depends on how the source is spelled (North Star 4)

- **Where:** `ownership.zig:7632`. On the `held_view` path,
  `spec.resource_list` is never set, so the element is no longer a
  `loop_view`.
- **Probes:** `k_src.rig`, `e1`–`e3`, `m6`, `c5`. With `src = ?a; for x in src`,
  the branch accepts `keep = x`, `z = <x`, `!b.push(<x)`, and `|<x|`. With
  `for x in ?a`, the same body is still rejected with `loop_view_rule`.
- **Soundness:** these programs are safe. They run clean under the sanitizer,
  and the oracle accepts them.
- **Fix:** pick one rule. Either drop `loop_view` for read-view elements whose
  loans are tracked, or set it on this path too.

## 3. LOW: writing an item in a chain loop changes only a copy (already on main; the PR adds forms)

- **Probes:** `bat/s19_w_w`, `bat2/t14_w_w`, and main's `s12_w_w`.
  `for x in !b.items().filter(f)` with `x += 10` is accepted, prints the new
  values, and leaves `b.xs` unchanged.
- **Contrast:** `for x in !b.items()` writes the elements.
- **Fix:** make chain loop bindings immutable, as other loop bindings are.

## Focus (2): `for`-source rule

No silent change found. I ran 360 programs: 45 sources, including `@`, `@bs[0]`,
`(!b)`, chains, Map iterators, and `text.lines`, each with four sigils and with
a read body and a write body.

- 0 programs gave different output under main and the branch.
- Every newly rejected program gets an error with a fix.
- Every newly accepted program is either correct or affected by issue 3.

## Focus (3): `?` marks

- **Unmarked forms are rejected** for all six consumers: in a binding, an
  assignment, after `??`, in `push`, in an object field, and in a method's
  return.
- **Marked forms are accepted** in a function, a method, on a parameter, and
  on a view binding.
- **Cosmetic:** the message for an unmarked `zip` names only `names`, though
  the items view `others` (`a6`).
