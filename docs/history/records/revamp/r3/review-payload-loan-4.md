# Review 4 of PR #94 (payload-loan), head d2a437c5, against 4fd21fa6 (base main 48f20f2a)

- **Scope:** `git diff 4fd21fa6 d2a437c5`: one type helper (`viewOfAccess`), `Facts.readsThroughWrite` and the `as` copy-out, `sema.checkBindingAccess`, L1 (a write view the match subject makes is lent on), and the hint changes.
- **Probes:** `.git/revamp/r3/review-payload-loan-4-probes/`, 105 programs (plus `j01_modules/`), with `probe.sh` and `results.txt`. `probe.sh` runs head `rig check` and main `rig check`. For each program head accepts, it then runs debug under `RIG_SANITIZE=1` and a `--release` build. Every program also goes through head's `bin/rig-oracle`. `equiv17/` holds the PR's newly accepted programs.
- **Builds:** d2a437c5 and 48f20f2a in fresh detached worktrees, each with `zig build` and `zig build oracle`. Both were removed at the end.

## Verdict

**Not safe to land.** There is one Critical finding, and it is new in this PR.

- **C1 (new):** L1's test for "a write view the subject makes" is negative: the subject's type is a write view, and its `hands` is not storage. `Hands.branches` covers any branch with a place leaf, plus `e?`, `a ?? b` and `e catch h`. So a read `match` over a branch or `?` whose leaf is a *place holding a write view* now binds `.write`. That place can be:
  - a field reached through a `?H` read view;
  - a field reached through a `*H` handle;
  - a bare `!E` parameter or local.

  The bindings then write through a read view, a handle, or an unloaned copy of a unique write view. Five such programs are use-after-free under the sanitizer in debug, and read freed memory in `--release` (they print `0` where `1` is right). Main rejects all five.
- **C2 (pre-existing, widened by L1):** a read `match` over a branching subject with a write-view place leaf copies the write view and keeps no loan on the leaf. The `as` path rejects this ("bare use of … would copy a write view"); `match` does not. Main also accepts five use-after-free programs of this shape. L1 now also lets those bindings write.

**What holds up:**
- **The legitimate L1 forms:** `match getw(!e)`, `match (!e if c else !d)`, nested branches, `catch !d`, `?? !d`, loops, closures, a generic call with two sources, and a method call. Every live conflict with `e`, `d` or `h` is rejected. Every accepted write lands in the original, for an Int, a Text, a `!P` field, a `![]Int` field, a Vec, a guard and a catch-all.
- **The `as` copy-out:** sound on all three header paths.
- **`checkBindingAccess`:** never fired falsely.

The 19 newly accepted programs I checked all run clean and print the right values.

---

## Critical

### C1. L1 lends on write views the subject does not make: writes through read views, handles, and copies of write views (new; use-after-free)

**Minimal program:** `c01_branch_readview_uaf_vec.rig`.

```rig
struct H
  w: !E

sub f(h1: ?H, h2: ?H, c: Bool)
  match h1.w
    .a(r0)
      s = ?r0.v[..]
      match (h1.w if c else h2.w)
        .a(r)
          for i in 0..100
            !r.v.push(i)
        .b => pass
      print(s[0])
    .b => pass
```

**Head:**
- `rig check` accepts it.
- `RIG_SANITIZE=1 rig run` reports: `error: rig: use of freed memory … rig.at(s, 0)`.
- `--release` prints `0`, and the caller's `e` shows the pushes.

**Main** rejects it: "cannot lend to write through a read view (`?T`)".

**Siblings, all accepted by head and rejected by main:**

| Probe | Subject | Leaf | Sanitizer |
|---|---|---|---|
| `c01` | `match (h1.w if c else h2.w)` | field through a `?H` read view | use of freed memory |
| `c03` | `match h.w?`, with `w: (!E)?` | field through a `?H` read view | use of freed memory |
| `l06` | `match (h1.w if c else h2.w)` | field through a `*H` handle | use of freed memory |
| `l07` | `match (getw(!x) if c else h1.w)` | a call and a read-view field mixed | use of freed memory |
| `c02` | `match (a if c else b)` | bare `!E` parameters, with `match a` reading `a` meanwhile | use of freed memory |
| `a03`, `a07`, `l03`, `l04` | as above, write only | | runs; Core violation (write through a read view or handle) |
| `a05`, `k02`, `k04` | bare `!E` parameters or locals, or `o?` of a local `(!E)?` | | runs; writes through an unloaned copy of a unique write view |

**Oracle:** silent on `c01`, `c03`, `l06` and `l07`, which is an oracle gap. It flags only the bare-parameter shapes (`a05`, `c02`), as "C2 a bare write view would be copied".

**Cause:** `typecheck.zig` `matchReach`, in the new line:

```zig
if (self.ctx.types.get(ty) == .write_view and !subject_hands.hasStorage()) break :blk .written;
```

- **Not a positive list.** `!hasStorage()` is true for `.made`, `.branches`, `.jump` and `.none`. `.branches` means "at least one leaf is not made here", which includes leaves that are places.
- **The `as` path is protected elsewhere.** It uses the same condition, but its header is walked as a consumed `.binding` (`ownership.zig`, `walkConsumed(…, .binding)`, then `checkNoImplicitCopy`). That walk rejects a bare write-view place leaf: `d04`, `f01`–`f05` are all rejected, "bare use of `h1.w` in binding would copy a write view". A `match` subject is not walked that way. So "lent on, as `if … as` lends one on" is not true: the `as` side has a guard the `match` side lacks.
- **This breaks two rules:**
  - AGENTS "one classifier per fact … by a positive list";
  - Core: a read view, and a handle, never write.

**Fix:**
- **Make L1 a positive list.** A match reaches `.written` only when the subject is `.made` (a call's result), or is `.branches` whose every value leaf (`sema.valueParts`, recursively) is `.made` or a write lend (`!x`). Every listed newly accepted program keeps working under that rule: `getw(!e)`, `(!e if c else !f)`, `(!v[i] if c else !v[0])`, `tryw(!e) catch !d` and `optw(!e) ?? !d`.
- **Add the shapes to `lendw.`** as cells: a branch of read-view fields, `?` of a read-view field, a branch of handle fields, a mixed call-and-place branch, and bare write-view parameters.

---

### C2. A read `match` over a branching subject with a write-view place leaf copies the write view and keeps no loan on it (pre-existing on main; L1 widens it)

**Minimal program:** `k01_prop_local_opt_two_writers.rig`.

```rig
fun g(e: !E) -> Int?
  o: (!E)? = <e
  match o?
    .a(r)
      s = ?r.v[..]
      if !o as w
        match !w
          .a(r2)
            for i in 0..100
              !r2.v.push(i)
          .b => pass
      print(s[0])
    .b => pass
  1
```

**Behavior:** accepted on both head and main. Both report a use of freed memory under the sanitizer. `--release` prints `0`.

**Siblings, all accepted and all use-after-free on both commits:**
- `d01`: `match (a if c else b)` of `!E` parameters, then `match !a`;
- `k03`: the same with `!E` locals;
- `k05`: `match (a if c else !d)`;
- `k06`: `match o ?? !d`, with `o` a local `(!E)?`.

**Why it is unsafe:**
- The subject reads the place leaf `o` or `a`, which copies the pointer.
- The binding's loans are the subject's, and none of them is a loan on `o` or `a` that a later `!o` or `!a` would hit. That is a second writer.
- The oracle reports the parameter forms as "C2 a bare write view would be copied; write `<` to move it". It is silent on `k01` and `k06`.

**Contrast:** `match o?` with an owning `o: E?` is rejected ("a `match` reads a place or takes a call's result; bind this `E` to a name first", `k07`). A write-view-typed branch skips that check.

**Fix:**
- Walk a `match` subject that has a write-view place leaf the way the `as` header is walked: as a consumed `.binding`, so the bare copy is rejected with the same message ("use `<a`", "write `!o`"). The other choice is to extend `k07`'s "bind this to a name first" rule to write-view types.
- C1's positive list alone does not fix C2. It only stops these bindings from writing.

---

## Medium (pre-existing, outside the diff; accept-means-correct)

### M1. `for x in v` over a `Vec[?P]`, then a field read: the program is accepted and the Zig fails

**Probes:** `i04` and `i05` (`for x in ?rv`).

```rig
  rv: Vec[?P] = Vec()
  !rv.push(?p)
  for x in rv
    print(x.n)
```

- **Behavior:** both commits fail in Zig: `type '**const __rig_main.P' does not support field access`.
- **Cause:** emit binds the slot by address, while the binding's type is `?P`. This is H2's class (the binding's emitted representation disagrees with its type), for loops.
- **Why the new check misses it:** `checkBindingAccess` passes, because the access (`.read`) and the type (`?P`) agree. The check compares the type with the access, not with emit's representation.
- **Existing coverage:** `vec_of_views.rig` tests only `Vec[?Int]`.

### M2. In a generic, a `|?x|` capture of a `match !g` binding fails in Zig for `T = Int`

**Probe:** `i07`.

```rig
fun poke[T](g: !G[T]) -> Int
  match !g
    .a(x)
      f = |?x| 2
      f()
    .b => 0
```

- **Behavior:** for `G[Int]`, both commits fail in Zig: `expected type 'i64', found '*i64'` at `.cap_x = x`.
- **Contrast:** the same program without generics (`i10`) runs, and so does a read match in a generic (`i08`).

---

## Low

### L1. The oracle misses writes through a read view or handle in a match subject

The oracle is silent on `c01`, `c03`, `l06`, `l07`, `k01` and `k06`. Since every probe the oracle abstains on goes unchecked by the second checker, record these as `ref-gap` in `test/oracle/differences` once C1 and C2 are fixed.

### L2. Two hints suggest forms the compiler rejects

- **The `as` read-binding hint** ("bind it with `if !o as x`") is given for a parameter `o` as well. Following it gives "cannot lend parameter `o` to write".
- **The branch-part hint** ("bind `(h1 if c else h2).w` to a name first, then match it with `match !`") works for `!H` parameters (`n02`). For `?H` parameters no write is possible at all, and the hint does not say so.

---

## What holds up

**L1's legitimate forms, a call's result or a branch whose every leaf is a write lend.** Every live conflict is rejected:
- reassigning the source (`e03`, `e05`, `e09`, `e11`, `e13`, `e17`, `m01`);
- reading the owner while the binding is live (`e04`);
- a second write lend of a source (`e06`, `m03`);
- a view held across loop iterations (`e15`);
- a method call's owner reassigned (`e18`);
- a generic `first(!v)` followed by `!v.push` while the binding lives (`e19`).

Every accepted write lands in the original, in both debug and `--release`:
- `e07` (both branches the same source), `e08` (nested branches), `e10` (`catch !d`), `e12` (`?? !d`), `e14` (loop), `e16` (`|!r|` capture), `m02` (two sources through a call);
- `g01`: `Int`, `Text`, `!P` and Vec payloads;
- `g02`: guards;
- `g03`: a `![]Int` payload;
- `g04`: a catch-all.

**The `as` copy-out (`readsThroughWrite`).**
- **All three header paths run correctly:**
  - viewed in place (`h05`, `h17`);
  - read through a view (`h03`, `h13`, `h18`);
  - the header copy (`h12`, `h19`, `h20`, for `!Int`, `!P`, `![]Int` and `!Text`).
- **The copy cannot go stale:**
  - the binding keeps its read loan on the optional, so `!o` while it or a capture of it lives is rejected (`h06`, `h11`);
  - the owner cannot be reassigned (`h01`);
  - `while … as` re-reads the copy each time round (`h05`).
- **No Cell is forked:** a `(!C)?` or `(!Cell[Int])?` binding is a pointer, and `set` reaches the original (`h07`–`h10`).

**`checkBindingAccess`.**
- **No false fire** on any of these:
  - generic match and loop bindings for `T` = Int, Text, a struct, `Vec[Text]` and `Vec[Int]`, in read, write and take forms (`i02`, `i08`, `i09`);
  - bindings of `Vec[?P]`, `(?P)?` and `Vec[String]` (`i01`, `i06`);
  - closures holding match, `as` and `for` bindings (`j02`, `j03`);
  - a two-module program using `match getw(!e)`, a branch match, a generic `peek` and a `?E`-returning call (`j01_modules`, which prints the right values).
- **Skipping a module with errors is safe.** The check only asserts, and a module with errors is rejected anyway.

**The newly accepted programs.**
- **All 19 run sanitizer-clean in debug and `--release`** with the right output (`equiv17/`). These are the 16 corpus programs named in equiv, plus the three behavior tests.
- **Spot checks of the output:** `review-step45-r2-b06`, `-r15d` and `-c03` print `322` (2 + 40×8); `p68` prints `2 2`; `g18` prints 50, then 70.
