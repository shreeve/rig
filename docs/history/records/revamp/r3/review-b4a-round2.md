# Review round 2: B4a fixes (b4-emit at b7e89291)

Targeted re-review of 2d06f2b3 (tests) and b7e89291 (fixes).

- **Probes:** in `probes/review-b4a/r2/`. The earlier probes are re-run
  from `probes/review-b4a/`.
- **Experiment copy:** `probes/review-b4a/work/rig-exp` was re-synced to
  b7e89291 and `experiment.py on` applied again (both rejections off).
  Its `rig-oracle` was rebuilt.

## Findings, ranked

**Critical / High / Medium: none.**

**Low (precision, not soundness, pre-existing):** the experiment still
rejects two forms whose emit reaches the place:

- `match w.r?` with a payload view leaving the function: "`v` does not
  live long enough".
- `if w.r as r` then a `match r` view returned: "cannot return a view of
  `r`, which this function was not lent".

Both are conservative. Emit holds the unwrapped view, which is a
pointer, so B4b could accept them later. Probes: `r2/z03`, and an
earlier version of `r2/z04`.

## Earlier findings, re-checked

| Probe | Under the experiment (both rejections off) |
|---|---|
| `x05`, `x05b` (all 5 forms), `x05c` | stay rejected: "this header binds a copy of its subject…" |
| `g20`, `g22`, `g24` | print correctly; also identical to v0.2.0 under b4a |
| `g21` | was a crash; now prints `t t` and `[1, 2, 3, 4] [1, 2, 3, 4]` |

Emit for `g20` is now `switch (rig.viewedPtr(Opt(T), &w.r).*)`, and the
guard binds `&rig.viewedPtr(Opt(T), &w.r).*.some.v`. No address of a Zig
rvalue remains.

## `startsOutsideHeader`: every path to a header temporary

All checked under the experiment. Each of these subjects is classified
as a copy and stays rejected (`r2/y01`–`y13`, `y15`, `z01`):

| Probe | Shape | Result |
|---|---|---|
| `y01` | chained calls `id(?id(?mk())).e` | rejected |
| `y02` | a failure propagated in the base, `id(?mkf(true)!).e` | rejected |
| `y03` | `catch` in the base | rejected |
| `y04` | `??` in the base | rejected |
| `y05` | a branching view base `(?mk() if c else ?w).e` | rejected |
| `y06` | a branch inside a call | rejected |
| `y07` | a view stored in a struct made in the header, `wrap(?mk()).r.e` | rejected |
| `y08` | a handle temporary through a view, `idh(?mkh()).e` | rejected |
| `y09` | a box temporary through a view, `idb(?mkb()).e` | rejected |
| `y10` | a direct handle field `mkh().e` | rejected |
| `y11` | a direct box field `mkb().e` | rejected |
| `y12` | a write lend of a temporary | rejected (in sema) |
| `y13` | `for` / `if … as` through a view of a temporary | rejected |
| `y15` | a lend of a path through a view of a temporary, `?id(?mk()).e` | rejected |
| `z01` | a plain-data made value at the base | rejected (a plain value lent to read is a statement temporary too) |

A method that returns a view of its temporary receiver is covered for
the same reason: the base walk stops at the call, whose evaluation makes
the temporary.

These forms correctly still point and run correctly (`viewname 42`,
`pick 42`, and so on):

- a name base with a temporary only in the index (`y14`);
- a view held by a name (`y16`);
- a call returning a view with no temporary in its base, and a temporary
  in the index (`y17`).

## `onSubjectPath`: deeper paths

These subjects are reached in place:

- `w.a.r`;
- `w.arr[1].r` (re-read);
- `w.arr[k(0)].r` (held once in `__rig_subject`; `k` is evaluated once);
- Vec elements `vs[i].r` and `vs[k(0)].r` (through `constSlot`);
- Vec elements that are themselves generic views, `vs[1]`;
- a view inside an optional, by `if … as` and by `?`.

Each is emitted as `rig.viewedPtr(Opt(T), &<path>).*`, and the results
are identical to v0.2.0 (`r2/z02`, `r2/z03b`).

Under the experiment, payload views escape from `vs[1]`, `vs[0]`, and
`w.arr[1].r` and print correctly after a stack clobber (`r2/z04`).

Box: a `Box` cannot hold a view, so there is no such path. A `for` over
a generic view of an array held in a field binds copies, and the checker
rejects a kept view (`r2/z05`), so it is not a sibling of the class.

## Regression

A sweep of 572 programs is byte-identical in sanitized output and
diagnostics between b7e89291 and v0.2.0. It covered my B4a probes, these
round-2 probes, `review-step10`, `review-step3` (with `r2`), and
`review-step45` (with `r2`).

The header classifier needed no second soundness fix in this round.
