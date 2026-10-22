# Review syntax-b, round 2 (PR #93, head 15b151da, base main 79768d0b)

This is an independent adversarial review of `git diff 4d8cb4a8 15b151da` (src/, test/oracle/, test/matrix.py). It covers the C1 fix (81b97d2f) and the `sliceview` matrix family (f76a6bdb).

**Method**
- Both commits were built in fresh detached worktrees (`zig build`, `zig build oracle`).
- Every probe was checked on both commits. Each probe the head accepts was run under `RIG_SANITIZE=1` in debug and in `--release`, and through `bin/rig-oracle -v`.
- Probes: `.git/revamp/r3/review-syntax-b-2-probes/` (about 150 files). Both trial fixes, for C2 and M1, are in `trial-fixes.diff` there.
- Probe families by prefix:
  - `a*`, `b*`, `c*`: how the owner is held, and how the view is obtained.
  - `d*`: write views of `![]T`.
  - `e*`: temporaries.
  - `f*`: std.text.
  - `g*`: `for` over bytes.
  - `h*`: Cell.
  - `m*`: `match !x` payloads.
  - `o*`: oracle.
  - `v*`: valid programs.
  - `*_arg`: the argument form of a bound probe.

## Verdict

**The C1 fix is correct, and safe to land.**
- The decider (`sliceLendsObject`) now classifies every slice I could construct correctly.
- Every member of the C1 class that main accepts and frees under is now rejected. That is 25 probes; each is a sanitizer use-after-free on main.
- The family `sliceview` passes on the head: 160 programs, 47 ran clean, 113 rejected, 0 failed, and the oracle shows 0 differences. With main's compiler, 8 cells of it fail as use-after-free, so the family catches the original bug.

**One Critical hole remains in the same symptom class, and main has it too (C2).**
- **Where:** inside a `match !x` arm.
- **What happens:** a view of a payload binding, written or bare, puts no loan on the binding. A later statement in the arm can then write through the binding while the view is live.
- **Why this is not the decider:** the decider says "lent", correctly. The ownership checker's `lendOn` then drops the loan.
- **Effect:** in safe code, a use-after-free on Text and on Vec.
- **Fix:** one line, tried below.
- **What the PR changes:** the PR adds no new hole. But the bare slice argument makes two more spellings reach C2 that main rejected for syntax (`m04`, `m09`).

**My recommendation:**
- Land, with C2 fixed before the tag. AGENTS: "a soundness finding from either gate is fixed before the tag".
- Better still, fold C2 into this PR, since it is one line.
- Fix the oracle regression M1 in this PR. It produces `prod=accept ref=reject` differences, which fail any oracle run that meets them.

---

## Critical

### C2. A loan of a `match !x` payload binding is not a loan on the binding (pre-existing; main the same)

**Minimal program:** `m02_match_bang_bound_written.rig`, shortened.

```rig
enum E
  a(t: Text)
  b

sub main()
  e = E.a(Text("hello"))
  match !e
    .a(t)
      s = ?t[1..]
      for _ in 0..50
        !t.add("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
      print(s)
    .b => print("b")
```

**Observed, on both the head and main:**
- `rig check` accepts it.
- Debug with `RIG_SANITIZE=1` stops with `use of freed memory`, then killed by signal 6.
- `--release` prints garbage, or nothing.
- The oracle reports `DIFF ... prod=accept ref=reject C4 cannot write `t` while a read loan of it is live`. So the oracle already catches C2, but no suite program reaches it.

**Expected:** `cannot lend `t` to write while a read loan is live`. Writing through a binding of `for t in !v` gives exactly this (`m11`), and so does writing through a binding of `if !o as w` (`m12`).

**Every probe in the class.** All are accepted and sanitizer-unclean, unless the table says otherwise.

| Probe | Form | Main |
|---|---|---|
| `m01` | `keep(?t[1..])`, then `!t.add` | same |
| `m02` | `s = ?t[1..]`, then `!t.add` | same |
| `m03` | `r = ?t`, then `!t.add` | same (breaks sentence 5; no free) |
| `m05` | the same, in a `!E` parameter's `match !e` | same |
| `m06` | `keep(t[1..])`, then `t = Text(...)` | same |
| `m10` | a `Box[Text]` payload, then `b = Box(...)` | same |
| `m13` | `match !e` of a `Box[E]` | same |
| `m14` | a Vec payload: `r = ?xs` / `s = ?xs[..]`, then `!xs.push` (release prints garbage Ints) | same |
| `m15` | a named payload, `.a(t: x)` | same |
| `b02_match_write_payload_arg` | bare `keep(t[1..])` | same (main: by C1 as well) |
| `m04` | a Vec payload, bare `keepv(xs[..])` | **new spelling** (main rejected it for syntax) |
| `m09` | a struct payload, bare `keep(p.t[1..])` | **new spelling** (main rejected it for syntax) |

**What is not affected:**
- A loan across statements outside the arm is kept (`m07`, `m08`).
- A loan within one statement is caught (`m17`).

**Cause.** `Checker.lendOn` in `src/ownership.zig`:

```zig
if (v.ref == .read or v.payload_view) return .{ .loans = held };
```

- **What goes wrong:** a payload binding is lent as if it were a read view. The view gets only the binding's own loans, which are a write loan on `e` held by the binding itself. It gets no loan on the binding.
- **The write that follows:** a write through the binding (`!t.add`) checks for loans on `t`, and finds none.
- **The class:** a write view held by a payload alias, lent on. The sibling sites are `for … in !v` and `if !o as w`, and both are correct: they take the `v.ref == .write` path, which adds a loan on the var.

**Fix (tried, not committed):**

```zig
if (v.ref == .read or (v.payload_view and v.ref != .write)) return .{ .loans = held };
```

- **Effect:** every `m*` probe above is rejected at the write, with "cannot lend `t` to write while a read loan is live" or "cannot reassign `t` while it is lent".
- **Cost:** a slice of a `match !e` binding can no longer escape its arm (`v09`, `v12`, `m08` say "`t` does not live long enough"). That is the same rule `if !o as r` already has (L3).
- **Better fix, if escaping should stay:** carry the loan onto the alias root when the binding's scope ends. The binding's loan on `e` already exists, so this is possible.
- **Suite:** with both trial fixes, the full suite passes (see the end of this file).

---

## High

None.

## Medium

### M1. The oracle now lends a read view, or a String, reached through a write view (new in 81b97d2f)

The new oracle condition in `placeValue`:

```zig
if (p.slice and (p.via == .own or (p.via == .write and !self.slicesString(p.slice_of)))) ...
```

- **Where it is wrong:** it lends whenever the path runs through a write view, unless the sliced value is a `String`. The compiler's decider, rightly, does not lend a slice of a `?Text`, a `?Box[Text]`, or a `?*Text`. So for a read view held in a field or element that is reached through a write view, the oracle rejects what the compiler accepts.
- **Programs:** they are sound, and run sanitizer-clean on the head.
- **Main's oracle:** silent on all of them.

**Minimal program** (`o01`):

```rig
struct R
  f: ?Text

sub g(w: !R, u: ?Text)
  s = w.f[1..]
  w.f = u
  print(s)

sub main()
  t = Text("hello")
  u = Text("other")
  r = R(f: ?t)
  g(!r, ?u)
```

- **Oracle output:** `DIFF o01... g prod=accept ref=reject C4 6:3 cannot write `w` while a read loan of it is live`.
- **Siblings:** `o16` (`?Box[Text]` field), `o17` (`?*Text` field), `o18` (local `w = !r`), `o19` (`!Vec[?Text]` element).
- **Not affected:**
  - a `[]T` field (`o02`), a `Vec[[]Int]` element (`o03`), and a `String` field (`o04`). `place()` already turns `via` to `.read` when it steps out of a `[]T` or a String;
  - a direct `!String`, which `slicesString` handles.
- **Why it matters:** the oracle's rule is that `prod=accept ref=reject` "always fails the run: it may be a soundness hole". The first suite or corpus program with this shape fails the oracle gate on a correct program.

**Fix (tried; `trial-fixes.diff`):** treat a read view like a String in `slicesString`, mirroring the compiler's `.text => types.get(obj_ty) != .read_view`:

```zig
return switch (self.ctx.types.get(t)) {
    .string, .read_view => true,
    else => false,
};
```

- **The five DIFFs:** gone.
- **The C1 class:** the oracle still rejects it (`c14`, `c15`, `c16`, `a22_arg`, `b01_arg`, `b18_arg`, `b23_arg`, `b24_arg`, `c03`: all `ref=reject`).
- **`./test/run -j 2 oracle`:** 5 of 5 sets pass, matrix included.
- **Test to add:** `o01` as a `# oracle: g accept` program, so the oracle's own tests pin the shape.

## Low

These are valid programs that main accepts and runs clean, and that the head now rejects. Each has a written alternative.

- **The cause:** the PR's rule is that a bare slice argument is its written `?` form. In each case below, that written form was already rejected on main.
- **Oracle:** it reports each of them as `stricter`, so if any one is added to the suite it needs an allowlist line.

### L1. A slice of a call's write-view result, as an argument (`c05`, `v07`)

```rig
fun get(h: !H) -> !Text
  !h.t
...
  s = keep(get(!h)[1..])      # head: "a view of the temporary `get(!h)` outlives its statement, which drops it"
```

- **Main:** accepts it and runs clean. The written `keep(?get(!h)[1..])` is rejected on both commits (`v01`).
- **Alternative:** `w = get(!h)`, then `keep(w[1..])` (`v02`).
- **The message is wrong:** a write view result drops nothing. `lendTemp` treats the view as a temporary that owns what it views. A slice of a `?Text` result is not treated this way (`e04`, s74, s79).
- **The proper fix:** lend through the view to what it carries. Track it with C2's follow-up.

### L2. A slice of a branch of write-view names (`v03`)

```rig
sub f(a: !Text, b: !Text, c: Bool)
  s = keep((a if c else b)[1..])  # head: "bare use of write view `a` in binding would copy a write view ... use `<a`"
```

- **Main:** accepts this, and also accepts the unsound `c06` (a use-after-free, which main's oracle flags).
- **The head:** rejects both, so `c06` is fixed. But `<a` is not the remedy.
- **Alternative:** `(?a if c else ?b)[1..]` (`v04`).
- **To fix:** improve the diagnostic.

### L3. A slice of an `if !o as r` binding cannot leave the `if` (`v05`, `v11`)

- **What happens:** "`r` does not live long enough". The written form is rejected the same way on main (`v06`).
- **Alternative:** a second `if o as r`, after the writes.
- **Inconsistency:** `match !e` allows the same escape (`v09`, `v12`), only because of C2. With C2's one-line fix, both forms behave the same.

### Notes (by design)

- **`for b in w[1..]` with `w: !Text`** now needs `?w[1..]` (`b04`), as `for b in t[1..]` with an owned `t` already does (`b03`).
- **`w[1..]` as a function's last value**, with `w: !Text`, needs `?w[1..]` (`b20`). The migration table should list both.

---

## What I checked and found sound on the head

Each item below is rejected with the right loan, or runs sanitizer-clean in debug and `--release`, with the oracle agreeing.

**The read-view claim.** I found no path that changes a Text while a read view's loan on it lives.
- **A Cell:**
  - `*Cell[Text]` cannot be sliced, lent as a String, or matched (`a19`, `h02`, `h03`).
  - The elements of a `Cell[Vec[Text]]` cannot be lent (`h04`) or walked (`h01`).
  - A Cell's struct fields are not reachable (`h05`).
  - `*Cell[Vec[Int]]` cannot be sliced (`a20`).
  - A Signal holds plain data only.
- **Shared handles:**
  - Handles only read.
  - Replacing the lent handle is rejected (`a13`, `b09`).
  - A second handle that is replaced (`a14`) or dropped (`a15`) leaves the Text alive, and runs clean.
  - Dropping the lent `*S` is rejected (`a28`).
- **A callable view holding `|!t|`:** passing it beside `?t` is rejected (`o13`).
- **A read view of a write view:**
  - `r = ?w`: writing (`a23`) or moving (`o08`) `w` while the slice lives is rejected.
  - The same for a `|?w|` capture (`o06`) and an implicit `cut(w)` (`o07`).
- **Read views reached through holders, and the slice keeps the original owner lent:**
  - a `?Text` field (`a01`);
  - a `!R` holding one (`a02`, `o05`);
  - a `Vec[?Text]` (`b05`);
  - a generic `Wrap[?Text]` (`o09`, `o14`);
  - `?String` and `?[]Int` read views (`a04`, `a05`);
  - a `!String` (`a03`).
- **Read views from headers and captures:**
  - `for t in ?texts` (`a06`);
  - `match e` (`a07`);
  - `if o as r` (`a08`);
  - `while o as r` (`a30`);
  - a `match e` on a `!E` parameter (`b13`);
  - `if ?w as r` (`c10`);
  - a `|?t|` capture (`a09`);
  - functions or methods returning `?Text` (`a26`, `a29`).
- **Read views of temporaries:** bound or kept past their statement, they are rejected (`e01`–`e03`, `e05`–`e07`). Used within the statement, they run clean (`e04`).

**Write views, now lent** (main accepted every one of these and is a use-after-free):
- `if !o as w` (`a22`);
- `|!t|` captures (`b01`, `b18`);
- `match !e` with the bound form (`b02`);
- nested `!` fields (`b23`);
- a local `!Box[Text]` (`b24`);
- a branch of write views (`c06`);
- a moved or re-lent `!Text` (`c12`, `c13`);
- a write view stored in a struct and written (`c14`) or assigned (`c15`);
- `Vec[!Text]` elements (`c16`);
- a generic `Wrap[!Text]` (`o10`);
- std.text over a write view (`f02`, `f03`, `f04`);
- the 8 `sliceview` cells.

**Already correct on both commits:**
- a `!Box` field (`b10`) and a `!*S` field (`b11`);
- an `![]Text` element (`b07`, `b08`, `d04`, `d05`);
- `!![]T`, which cannot be passed, and cannot be written through (`d01`–`d10`);
- `for` over a write view's bytes or elements, written in the body (`g01`–`g04`);
- `o?[..]` of an optional Text (`b14`–`b16`);
- generic bodies, which cannot slice a `T` (`a11`, `a12`).

**Other gates:**
- `test/matrix.py -k sliceview`: 160 programs on the head, 0 failed. With `--oracle`, 0 differences.

## Both trial fixes together

- **The tree:** the head, with C2's one-line `lendOn` fix and M1's oracle fix (`trial-fixes.diff`).
- **`./test/run -j 2`:** 3008 passed, 0 failed, 3 pending.
- **`./test/run -j 2 oracle`:** 5 of 5 sets pass.
