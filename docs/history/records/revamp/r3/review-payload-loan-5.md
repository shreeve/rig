# Review 5 (final) of PR #94 (payload-loan), head d73cebf6, against 48f20f2a

- **Scope:** `git diff 48f20f2a d73cebf6`, focused on `d2a437c5..d73cebf6`: `sema.makesWriteView`, `sema.headerCopiesWriteView`, the converted conditions in `matchReach` and `checkOptionalBinding`, and the hints.
- **Probes:** `.git/revamp/r3/review-payload-loan-5-probes/`, 99 programs, with `probe.sh`, the generators in `gen/`, and `results.txt`. `results.txt` also has the first runs of `a02`, `a04`, `a10`–`a13` and `a16`, before I lent their arguments with `!`; the reruns follow them.
  - `probe.sh` runs head `rig check` and main `rig check`. For each program head accepts, it runs debug under `RIG_SANITIZE=1` and a `--release` build. Every program also goes through head's `bin/rig-oracle`.
  - `equiv30/` holds the 30 newly accepted programs.
- **Builds:** d73cebf6 and 48f20f2a, each in a fresh detached worktree, with `zig build` and `zig build oracle`. Both were removed at the end.

## Verdict

**The PR's new code is sound, but the class it claims to close is still open. Fix that here before landing, or at the latest before the tag.**

- **The new deciders hold up.** `makesWriteView` accepted nothing unsound in about 30 attempts on the write side. `headerCopiesWriteView` catches every top-level branch I gave it. The 30 newly accepted programs all run sanitizer-clean, give the same output in debug and `--release`, and print the right values. I found no regression against main.
- **Two Critical findings, both on main and both in C2's class:** a header reads a write view, or a value holding one, out of a place through a branch, and keeps no loan.
  - **C1:** `headerCopiesWriteView` looks only at a subject that is itself a branch. A *path through a branch* passes:
    - `(a if c else b).f`
    - `(a if c else b)[0].f`
    - `o?.f`
    - `h.o?.f`
    - `(o ?? g).f`

    This holds for `match`, `if … as`, `while … as` and `for`.
  - **C2:** `for` never calls the decider, so review 4's own C1 and C2 shapes still pass as `for` sources: `for x in (a if c else b)`, `o?`, `o ?? !d`, and `(h1.v if c else h2.v)`.
  - **Impact:** 17 accepted programs report "use of freed memory" under the sanitizer in debug. In `--release` they read freed memory: they print `0`, or panic with an integer overflow on the garbage they read.
- **Grading:** these are not regressions, so landing would not make main less safe. But the PR body says C2 is fixed, and AGENTS asks to "fix the class, not the instance". The fix sits in the same decider and is small (below). Under "Land fast, release deep", a soundness finding blocks the tag in any case.

---

## Critical

### C1. A header over a path through a branch copies a write view with no loan (on main; C2's class)

**Minimal program:** `d10_branch_part_writeviews_reassign_param.rig`.

```rig
struct W
  e: E

sub f(a: !W, b: !W, c: Bool)
  match (a if c else b).e
    .a(r0)
      s = ?r0.v[..]
      a.e = mk(9)
      print(s[0])
    .b => pass
```

- **Behavior:** head and main both accept it. Under the sanitizer it reports "use of freed memory". `--release` prints `0`.
- **Oracle:** "C2 a bare write view would be copied", so this is a DIFF.

**Accepted on both commits, all use-after-free under the sanitizer (debug), all wrong in `--release`:**

| Probe | Header | Subject | Leaf reached |
|---|---|---|---|
| `b01` | `match` | `(h1 if c else h2).w` | `!H` parameters holding `!E` |
| `b02` | `match` | `(h1 if c else h2).w` | owned `H` locals holding `!E` |
| `b09`, `d10` | `match` | `(a if c else b).e` | `!W` parameters |
| `d11` | `match` | `(a if c else b).e` | `!W` locals (`a = !x`) |
| `d07b` | `match` | `(a if c else b)[0].e` | `!Vec[W]` parameters; the binding itself dangles after a push |
| `b03` | `match` | `o?.w` | a local `G?` holding `!E` |
| `d03` | `match` | `h.o?.w` | through a `!H` parameter |
| `d04` | `match` | `(o ?? g2).w` | owned locals |
| `b11` | `if … as` | `(a if c else b).o` | `!G2` parameters, `o: (!E)?` |
| `c05` | `while … as` | as `b11` | |
| `c04` | `for` | `(a if c else b).v` | `!W` parameters; `--release` panics |
| `d06` | `for` | `og?.v` | a local `G?` holding `!Vec[Int]`; `--release` crashes |

**More siblings:**
- `c08`: a `|?x|` capture of `b11`'s binding while `!a.o` writes. It runs, but a live read view sees a write (Core sentence 5).
- `c09`: an index path; runs only by luck.
- `d09`: read-only; runs, but the oracle reports C2.

**Accepted on both commits and failing in Zig (Medium, accept-means-correct), same root:**
- `c11`: `match (tg(!a, false) catch |_| b).e`, with `b` a bare `!G`, gives `expected type '*G', found 'G'`.

**Cause.** `headerCopiesWriteView` returns null unless `isBranchingForm(subject)`. A member or index of a branch is not a branching form, and it reaches the header in one of two ways:
- **As `.place`:** `pathHands` gives `.place` when the branch's type is a view (`(a if c else b).e`). The binding is then a read view of a "place" rooted at a branch. Ownership has no variable to put the loan on.
- **As `.part_of_made`:** `pathHands` gives `.part_of_made` when the branch's type is not a view (`(h1 if c else h2).w` of owned `H`, `o?.w`). The `k07` rule ("bind this to a name first") is skipped for a write-view-typed part. For `b09` it is skipped because the path counts as a place.

The lend path already rejects every one of these shapes:
- `c01`: "cannot lend `a if c else b`: it may be `a`, a value a name holds, which lending the branching value would copy";
- `c07`: the same, for owned locals.

The header paths have no such check.

**Fix:**
- **Walk to the path's base.** In `headerCopiesWriteView`, walk member and index steps from the subject down to the base (`pathRoot`, through `?.` too). If that base is a branching form, apply the same leaf test to its value leaves.
  - For `b09`, `holdsWriteView(!W)` is already true.
  - For `?W` leaves it is false, so `d08` (read-only, through read views) stays accepted.
- **Call it from `checkFor`.** Apply it to the source, and to the operand of `?source`.
- **Matrix:** add `lendw.` cells for branch-part subjects and the three other headers.

### C2. `for` never consults `headerCopiesWriteView` (on main; review 4's C1 and C2 shapes, as `for` sources)

**Minimal program:** `h03_for_coalesce_place_and_lend.rig`, review 4's `k06` written as a loop.

```rig
fun f(v: !Vec[Int], d: !Vec[Int]) -> Int?
  o: (!Vec[Int])? = !v
  n = 0
  for x in o ?? !d
    if !o as w
      for i in 0..100
        !w.push(i)
    n += x
  print(n)
  1
```

**Siblings, all accepted on both commits and all use-after-free under the sanitizer:**

| Probe | Source | `--release` |
|---|---|---|
| `c03` | `(a if c else b)` over `!Vec[Int]` parameters | panics: integer overflow on freed memory |
| `h01` | `o?` | crashes |
| `h02` | `(h1.v if c else h2.v)` over `!H` fields | crashes |
| `h03` | `o ?? !d` | crashes |

`b08` has the same shape and runs only because the loop's length was read before the reallocation.

**Cause.** In `checkFor`, a `.branches` source with a view type matches neither the `unbound` error (which wants a bare `Vec`) nor any copy check. The PR's structural test pins `headerCopiesWriteView` to exactly two callers, `checkMatch` and `checkOptionalBinding`. So `for` was never in scope, although the binding kinds this PR covers include `for`.

**Oracle:**
- **Flags** `c03` and `h02` (C2).
- **Silent** on `h01`, `h03`, `d06`, `b02`, `b03`, `d03` and `d04`, every shape whose leaf is an optional or an owned value holding a write view. This is a `ref-gap`.

---

## Medium

### M1. `(… catch |_| b).e` with a bare write-view handler is accepted, and the Zig fails (on main)

See C1, `c11`. The class fix rejects it.

---

## Low

### L1. A new oracle DIFF on a newly accepted form

- **The form:** `a05c`, `match (!h).gw()` where `gw(!self) -> !E` returns `!self.w`, and `w` is a write-view field. Head accepts it, and it runs correctly (`[1, 0, 1, 2]`).
- **The DIFF:** the oracle rejects it: "C4 cannot write `r` while a write loan of it is live (L4, carried by `h`)".
- **Pre-existing:** the same false positive exists on main for `w = (!h).gw(); match !w` (`a05e`) and for `a07d`.
- **What to do:** L1 exposes the false positive to a new form. Classify it in `test/oracle/differences`, or fix the oracle's model of a write view a method returns from a write-view field.

### L2. A hint leads to a rejected program

`d02`'s hint says "bind `(!a if c else !b).e` to a name first, then match it with `match !`".
- **Following it (`d02b`):** "bare use of `E` value … would alias an owning value".
- **What works (`d02c`):** `t = (!a if c else !b)`, then `match !t.e`.
- **Also:** the message prints the subject as `!a if c else !b.e`, without parentheses.

### L3. A read-only branch of read-view fields gets a hint that skips its working alternative

- **The rejection:** `f04`, `match (h1.w if c else h2.w)` with `?H` parameters, is rejected with "match `h1.w` where it stands".
- **The missed alternative:** `match (?h1.w if c else ?h2.w)` runs (`f03`).
- **Covered by the cost table:** `f04`, `f06` (`match o?`) and `f09` (`catch w`) are in its last row. `f07` shows the `if o as x` alternative runs.

### L4. One default in the `as` path still falls toward write

- **Where:** in `checkOptionalBinding`, a reach left at `.copied` with a view inside (`(!T)?`) becomes `decideBindingAccess(.declared = !T)`, which is `.write`. `.copied` is a default: it means "neither written nor read".
- **Why it is sound today:**
  - The legitimate cases (`!o` through a write view, a made optional) want `.write`.
  - The bare `p: !((!E)?)` case is rejected by ownership's binding walk ("bare use of write view `p` in binding would copy", `g01`–`g03`).
  - C1's `b11` reaches `.read`, not this default.
- **Suggestion:** a positive `.made` / `.lent` reach would make the access independent of that later walk.

---

## The positive lists: what holds

### `makesWriteView`: nothing it accepts writes through a read, a handle, or a copy

Each of these was rejected, by sema or by ownership, before it could write:
- **A call over a read-view field or a handle field:**
  - `getw(h.w)` with `?H` (`a01`) or `*H` (`a15`);
  - the generic `id(h.w)` (`a03`, `a04b`).
- **Methods:**
  - `?self` returning `self.w` (`a05`);
  - `!self` called on a read view (`a05b`).
- **Closures:** returning `!e`, `e`, or `h.w` of a capture (`a06`–`a06d`).
- **`<` of a field:**
  - `<h.w` of a `!H` field;
  - `<h.o` through `?H` (`a07b`) or `*H` (`a07c`).
- **Loop values and `match` values** of a bare write view (`a08`, `a09`).
- **Mixed leaves:**
  - `optw(!x) ?? h.w`, and `catch |_| h.w` (`a10`, `a13`);
  - `Vec[!E].get` (`e01`–`e07`, `e10`), `for x in !v` over `Vec[!E]` (`e08`), and `Cell(!e)` (`e09`).
- **Live conflicts:** bare write-view arguments must be lent with `!`, and once they are, every live conflict is rejected (`a02`, `a04`, `a12`, `a16`, `a17`).

The legitimate forms run correctly:
- `a05c`: a method's `!self.w`;
- `a11`: `tryw(!x, true)!`;
- `d01`: `(!a if c else !b).e`, where a live `!a.e` is rejected;
- `d02c`.

**Why the `.call` entry is sound:** a call's write view always comes from write-lent arguments. Every attempt to make a call return a write view from a read view, a handle, a capture, or a copy failed in the callee or at the argument.

### `headerCopiesWriteView`, for top-level branches

These are all rejected, each with a correct hint:
- nested branches (`b05`);
- parenthesized leaves (`b06`);
- fields of fields (`b07`);
- index leaves (`b10`);
- `catch` and `??` with a place leaf (`f09`, `a10`, `a13`).

The holes are only paths through a branch, and `for` (C1, C2).

### Remaining "not X" logic

- **All four conversions the PR lists are done**, as stated.
- **Every remaining default falls to the safe side:**
  - `matchReach` falls to `.read`;
  - `decideBindingAccess` falls to none (owner), or `.read` for a slice;
  - `lendTarget` falls to `.owner`;
  - `viewOfAccess`'s `.read` falls to a value for `copies != .no`.

  The one exception is L4.
- **Negative conditions outside the diff:** `checkFor`'s `unbound` (`!hasStorage() and kind != .made`) is negative. It is where C2 slips through.

## The 30 newly accepted programs

- **The set:** I recomputed it with `rig check` over the 11,259 programs in `test/` and `examples/`. Head accepts 4,977; of those, main rejects exactly 30, the PR's count.
- **The runs:** all 30 run sanitizer-clean in debug, and their debug and `--release` output match (`equiv30/results.txt`).
- **Spot checks against the source:**
  - `e10` (`catch !d`, then the ok path) prints `[2, 42]`, then `[1, 43]`;
  - `h19` prints `5 qq 5 5`, `2`, and `3 2 4` for `c = false`;
  - `review-step45-*` print `322`;
  - `g18` prints 50, then 70;
  - `e08` writes only the chosen branch.

## Over-rejection beyond the cost table

None found. `f04`, `f06` and `f09` are rejected as the last row of the table says, and their alternatives run (`f03`, `f07`). `f01` and `f02` are rejected on main too.
