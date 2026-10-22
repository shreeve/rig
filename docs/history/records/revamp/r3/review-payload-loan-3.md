# Review 3 of PR #94 (payload-loan), the redesign, head 4fd21fa6, base main 48f20f2a

- **Scope:** `git diff 48f20f2a 4fd21fa6`, chiefly the redesign commits since `payload-loan-r1` (14d85287): `sema.decideBindingAccess`, `SemContext.bindingAccess`, `bindMatchView` / `asAccess` + `asBindingType` / `loopElement`, `lendTarget`, `payloadByAddress`, `Facts.payloadReadsThroughWrite`, and the structural unit test.
- **Probes:** `.git/revamp/r3/review-payload-loan-3-probes/`.
  - About 120 hand-written programs, with `probe.sh` and `results.txt`. `probe.sh` runs head `rig check` and main `rig check`. For a program head accepts, it then runs debug under `RIG_SANITIZE=1` and a `--release` build. Every program also goes through `bin/rig-oracle`.
  - `gen_grid.py` writes `grid/`: 912 programs that extend matrix.py's `lendw.` family with 38 more binding kinds (20 write, 18 read). Two of the write kinds, `w_for_index` and `w_if_as_param`, are malformed by the generator and rejected for unrelated reasons; hand probes `p01`–`p03` cover them instead. `run_one.sh` produced `grid_results.tsv`, and `rel_one.sh` produced `rel_results.tsv` (`--release`).
- **Builds:** 4fd21fa6 and 48f20f2a in fresh detached worktrees, each with `zig build` and `zig build oracle`. Both were removed at the end.

## Verdict

**For ownership, the redesign closes the class.** I found no use-after-free, leak, or wrong output in any program head accepts.
- **Live writes:** every live lend-then-write of a write binding is rejected, for all 20 extra write-binding kinds × 4 types × 3 lends. Main accepts 108 of those 240 live cells (C2).
- **Read bindings:** every write through a read binding of a write view is rejected, for 18 extra read-binding kinds × 4 types × 3 lends × 2 timings. Main accepts 78 of those 216 cells (C1).
- **Non-overlapping lends:** every "after" cell head accepts runs sanitizer-clean in debug, and the text cells also in `--release`, printing the right values.
- **Ownership checks:** `lendTarget` reads only the access, and the fact covers every binding kind I could build.

**It is not safe to land as is, because of one High finding (H1).** It breaks accept-means-correct and is new in this PR.
- **What goes wrong:** the `as` path derives the binding's type through its own helper (`asBindingType`), not the one matches use (`viewOfAccess`). A read `if o as x` reached through a view of a `(!T)?` is now typed `?!T`, a read view of a write view.
- **What happens:** Rig accepts programs using such an `x`, and the Zig fails to compile:
  - when `x` is captured `|?x|`;
  - when `x` is put in an array (`[x]`).

  On main, the same programs either run correctly or are rejected in sema.
- **The same root cause** also explains the following:
  - **H2:** a pre-existing Zig failure for local and field optionals;
  - **M1:** newly rejected programs that have no alternative;
  - **M2:** docs that say the opposite of what the code does.
- **Fix:** have `as` derive its type with `viewOfAccess`, as matches do: `!T` read as `?T`, `![]T` read as `[]T`, and emit's copy-out for scalars. That fixes H1, H2 and M1 together.

**No soundness finding.** H1 and H2 are compile failures of accepted programs, not memory errors.

---

## High

### H1. `if o as x` over a read view of `(!T)?` binds `?!T`, and capturing it or putting it in an array emits Zig that does not compile (new in this PR)

**Minimal program:** `n01c_param_readas_closure.rig`.

```rig
struct P
  t: Text
  n: Int

sub f(o: ?((!P)?))
  if o as x
    g = |?x| x.n
    print(g())

sub main()
  p = P(t: Text("hello"), n: 3)
  o: (!P)? = !p
  f(?o)
```

**Head:**
- `rig check` accepts it.
- `rig run` and `--release` both fail in Zig:

  ```
  error: expected type '*const *__rig_main.P', found '*__rig_main.P'
          }{ .cap_x = x }; _ = &g;
  ```

**Main:** runs sanitizer-clean in debug and `--release`, and prints `3`. There `x` was `!P`, which was main's hole, so it was not sound either.

**Siblings, all accepted on head with the same Zig error:**

| Probe | Form | Main |
|---|---|---|
| `n01c` | `|?x|` of `?!P` (param path) | runs, `3` |
| `n13` | the same inside `while o as x` | runs, `3` |
| `n06` | `|?k| k == 5` of `?!Int` | runs, `true` |
| `n04` | `arr = [x]` of `?!P` | rejected in sema ("bare use of write view `x`") |
| `n18` | `arr = [k, k]` of `?!Int` | rejected in sema |

**Cause.**
- `checkOptionalBinding` now sets `reach = .read` for a view inside an optional reached through a read view or handle (typecheck.zig, the new line after `reachThrough` in the `else` branch). `asBindingType(.read, !P)` then gives `?(!P)`.
- Emit binds `x` from the optional's payload as the `*P` the optional holds (`if (o.*) |x|`), but spells the type `?!P` as `*const *P`. So any place that writes the binding's type next to its value fails:
  - a capture field;
  - an array element type.
- A match binding of the same field goes through `viewOfAccess`, which reads `!T` as `?T` (and `![]T` as `[]T`). It works: `q01` captures `|?w|`, `|?k|` and `|?s|`, and builds `[k, k]`, on read-match bindings of `!P`, `!Int` and `![]Int`. It runs clean and prints `3 6 3 5 hello`.

So two helpers that derive "the type the access gives" disagree for the same access and the same reached type. That is the very kind of disagreement the redesign set out to remove.

**Ask.**
- Derive the `as` binding's type with the same helper as matches, so `.read` of `!T` gives `?T` and of `![]T` gives `[]T`.
- Extend `Facts.payloadReadsThroughWrite`'s copy-out (`.*`) to an `as` binding of a write view of a scalar or view. The PR already lists this as a follow-up; H1 makes it required.
- Add `n01c`, `n06`, `n13`, `n04` and `n18` to the suite, and an `as` cell to `lendw.` / `cellmut.`. `cellmut.optional` uses only `T?`, never `(!T)?`.

### H2. The same type through a local or field optional: reading a field of `y` fails in Zig (pre-existing; main the same)

**Minimal program:** `m01_local_opt_wv_print_field.rig`.

```rig
struct P
  t: Text

sub main()
  p = P(t: Text("hello"))
  o: (!P)? = !p
  if o as y
    print(y.t)
```

- **Behavior:** accepted on both commits. Both fail in Zig with `type '*const *__rig_main.P' does not support field access` (`&y.t`), in debug and `--release`.
- **Siblings, the same on both commits:**
  - `m03`: `while o as y`;
  - `m04`: `if h.o as y`, a field;
  - `n02`: `.xs.len`;
  - `n22`: through a `*H` handle, `|?x|`;
  - `n23`: a `?H` parameter's field, `|?x|`.
- **Cause:** here the `if` views the optional in place (`viewed`), so emit binds a pointer to the payload slot, `*const *P`, and field access needs two dereferences.
- **Why it belongs here:** it is not caused by this PR, but it has the same root as H1 (the `as` path types a read binding of `!T` as `?!T`), and the same fix removes it. I list it so the fix covers both the `viewed` path and the through-view path.

---

## Medium

### M1. Unlisted newly rejected programs, with no alternative: reading a `?!T` as a `?T`, `[]T` or `Int` (new in this PR)

**Program:** `i02_read_as_pass.rig` (also `i03`, `h09`, `i07`, `n17`).

```rig
struct P
  t: Text
  n: Int

fun show(q: ?P) -> Int
  q.t.len

sub f(o: ?((!P)?))
  if o as x
    print(show(x))

sub main()
  p = P(t: Text("hello"), n: 3)
  o: (!P)? = !p
  f(?o)
```

**Main:** accepts these, and they run sanitizer-clean:
- `show(x)` prints `5`;
- `total(s)` for `s` from `?((![]Int)?)` prints `6`;
- `k + 1` for `?((!Int)?)` prints `6`;
- `m: Int = k` prints `5`;
- `g = |+k| k == 5` prints `true`.

**Head rejects each one:**
- "type mismatch: expected `?P`, got `?!P`; … lend it on where it goes (`?!P` or `!!P`)";
- "operator `+` requires numeric operands; got `?!Int`";
- "`|+k|` … but `k` is `?!Int`".

**No alternative works.** I tried `show(?x)`, `y: ?P = x`, `y = ?x` (then `show(y)`), `show(x?)` and `show(?(x))`, and every one is rejected. The hint itself is circular: `?!P` is not accepted where `?P` is expected.

**What the PR says.** It mentions only "`w + 1` fails" for `if o as x` of a `(!T)?`, and calls it something the binding "keeps". On the `?((!T)?)` parameter path, though, the type is new in this PR, and these programs are not in the cost table or in `test/oracle/differences`.

**Fix:** the H1 fix makes all of them run (`x: ?P`, `s: []Int`, `k` a copied `Int`).

### M2. The docs say `as` reads a write view as `?T`; the code makes it `?!T` (new in this PR)

- **What the docs say:** INTERNALS "Binding access" says typecheck "derives the type from it: … a read view of it (a write view `!T` read as `?T`, `![]T` as `[]T`)". SPEC §match says a read match binds a write view field as `?T` "as `if o as x` does".
- **What the code does:** `asBindingType` makes `?(!T)`, and `loopElement` uses the same helper.
- **Why it matters:** AGENTS rule 1 does not allow docs to claim behavior the suite does not check. The H1 fix makes the docs true.
- **Also:** the PR body says "Typecheck derives binding types from it, through three helpers". There are two type helpers with different answers (`viewOfAccess` and `asBindingType`). One helper would make H1's kind of disagreement impossible to write.

---

## Low

### L1. `match (!e1 if c else !e2)` now binds read views; `if (!o1 if c else !o2) as x` still writes (unlisted cost; inconsistent)

**Program:** `l06_match_branches_subject_after.rig`.

```rig
  match (!e1 if c else !e2)
    .a(w)
      w.t = Text("other")
    .b => pass
```

- **Main:** accepts it, and it runs clean, printing `other bye`.
- **Head:** rejects it with "cannot assign through a read view (`?T`); take a write view (`!T`) to mutate", which carries no hint.
- **Why:** `matchMode` is `.read` because the subject is not a `.write` node, and `matchReach` is `.read` because the subject is `.branches`, not `.made`. So every binding is `.read`.
- **The `as` path differs:** the same subject shape gets `.written` (`l07`, accepted, runs). The PR says a write needs `match !`, but neither `match !(e1 if c else e2)` nor `match !(!e1 if c else !e2)` is accepted ("lend what each branch reaches instead").
- **The only alternative:** split the match by `if c`.
- **Ask:** classify a branch whose every branch is a write lend as `.written` in `matchReach` (it is a positive case, like `.made`), or list the shape in the cost table.

### L2. The `match !` hint is missing for some read-match subjects

- **Subjects without the hint.** A write through a binding of these gives only the generic "take a write view (`!T`) to mutate":
  - `match get(!h)` (`l08`);
  - `match o?` (`e02`);
  - `match o ?? E.b` (`e03`);
  - a branch subject (`l06`);
  - a read `if o as x` of a `?((!P)?)` (`h01`).
- **Why:** `readMatchHint` needs `copied_from`, and these subjects do not record it.
- **Alternatives that exist but are not named:**
  - `match !get(!h)` works;
  - for `o?`, `if !o as e2` then `match !e2` works.
- **Main for comparison:** main accepted `e02` and `e03`, which write through a read match. Both run clean, and both are the r1 C1 shape, so rejecting them is intended.

### L3. The structural test pins the call sites, not the agreement between fact and type

**What the test checks:**
- `decideBindingAccess(` occurs three times in typecheck;
- the fact is recorded at three sites;
- `lendTarget` reads only the fact.

**What it cannot catch:**
- **H1's kind of drift:** two type helpers giving different types for one access, or emit spelling a type its binding's value does not have.
- **A wrong but agreed answer:** `bindingAccess` falls back to the declared type for any symbol with no recorded access. A future binding kind that typecheck types `!T` without going through the decider would get `.write` from its type. Typecheck and ownership would then agree on the wrong answer, which is the C1 shape.
- **Mode read elsewhere:** ownership still reads a var's mode from `v.ref` (`refOfType`) in `checkAssignable`, `reassign`, `writesThroughLocal` and `viewedRoot`. These agree today, because the type follows the access, but nothing checks it.

**Ask:**
- In a debug build, check after typecheck that every symbol with a recorded access has a type that agrees with it:
  - `.write` with a write view;
  - `.read` with a read view, a slice, a String, or a type parameter's `T`.
- Have the `as` path use the same type helper as `match` (H1). One helper, plus that invariant, makes the class structural.

---

## What holds up

**Binding coverage, every write binding rejected while a lend is live.** On main, 108 of the grid's 240 live cells are accepted, and every one of those has the C2 shape.
- **The grid's write bindings** (20 kinds × 4 types × 3 lends):
  - `match E.a(!y)` (`read_own`);
  - named fields;
  - a `Box[E]`, a field, an element, or a generic `G[TY]` subject;
  - a `!TY` payload, matched with `match !e`;
  - a guarded arm;
  - nested `match !o` → `match !i`, also through a `!E` payload;
  - `match !get(!h)`;
  - `while !o as b`;
  - `if !h.o as b`;
  - `if !o as b` on an optional payload;
  - `for b in !arr`;
  - a `|!b0|` capture of a payload;
  - `b = !b0` held from a payload;
  - a `defer` in the arm.
- **Hand probes, also rejected while live:** `test` blocks (`o01`), `defer` blocks (`o02`), `!self` methods (`o04`), `if !o as b` on an `!(Text?)` parameter (`p01`), and `for b, i in !v` (`p03`).
- **When the lend ends first:** every such program runs clean, printing the view and then the result of the write.

**Read bindings of write views, every write rejected** (18 kinds; grid and hand probes):
- **Subjects:** a Box, a field, an element, named fields, a generic `G[!TY]`, a guard, a `?E` parameter, a call returning `!E`, a field of a `*H` handle, nested reads under `match !o` or `match o`, a part of a made value, and a catch-all of a `!E` parameter.
- **`as` forms:** `if o as b` through a parameter, a local, `while`, a payload optional, and a `match !e` payload optional.
- **A struct holding `!P`:** writes through a read binding of it are rejected by path, method, re-lend, closure, `for` and `if … as` (`b01`–`b07`).
- **Re-wrapping the inner write view is rejected:** `H(w: h.w)`, `put(h.w)`, `k: !P = h.w`, `(!P)?`, `[h.w]`, and a match value (`d01`–`d09`).

**`read_own` (`match E.a(!p)` binding `!P`) is sound:**
- `p` stays lent while `w` lives (`e08`);
- a live lend then write is rejected (`e07`), and so are two writers through a closure (`e10`);
- the plain use runs clean (`e06`).

Subjects that only look made are not `read_own`: `o?`, `o ?? E.b` (which leaves `o` usable, `e03b`) and branch subjects are `.read`.

**Owner fallback (no access) keeps held loans:**
- A slice local, a slice payload, a String payload, a slice `for` element, and an `if o as s` of `([]Int)?` each relend and then write the source. All are rejected, as on main (`a01`–`a06`).
- So when `lendTarget` returns `.owner` for a `payload_view` var with no access (a change from main's `.read_view`), it loses no loan.

**Elsewhere:**
- **Generics:** a read binding `x: T` cannot be lent to write (`c05`, `c06`), and its subject cannot be reassigned while a view of it lives (`c02`, `c03`). `c04`, a C2 shape that main runs, printing the new value through `r`, is now rejected.
- **Moving a write binding out:** `match !e` / `if !o as` / `for in !v` values used past the construct keep the subject lent (`f01`–`f05`).
- **`!self` / `?self`:** lends of `self` and views returned from methods work as on main (`g01`, `g02`), even though `bindingAccess` reads the symbol's type and not the `sugar` ref.
- **Alternation patterns:** they cannot bind names, so no alternatives can disagree on a binding's access (`k01`, `k02`).
- **Emit copy-out:** a read-match binding of `!Int`, `!P` or `![]Int` used in `|?w|`, `|?k|`, `|?s|` and `[k, k]` runs clean (`q01`). This is the H1 shape, through `viewOfAccess`.
- **Oracle:** silent on every probe. The only output is `stricter` lines on `f02`, `f02b`, `f04`, `f04b`, `j04` and `j05`, where the compiler is the stricter one.
