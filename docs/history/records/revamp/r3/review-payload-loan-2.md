# Review 2 of PR #94 (payload-loan), head 14d85287, base main 48f20f2a

- Scope: `git diff 310f5ecb 14d85287`, the C1 fix (typecheck `readsHeldWriteViews` and `readViewOfWrite`, `Facts.payloadReadsThroughWrite`, emit `.*`, `rejectWriteViewBindings` by field, and the docs).
- Probes: `.git/revamp/r3/review-payload-loan-2-probes/` (116 programs, `probe.sh`, `results.txt`).
  - `probe.sh` runs each probe through head `rig check` and main `rig check`. For an accepted probe it then runs debug under `RIG_SANITIZE=1` and a `--release` build. Every probe also goes through `bin/rig-oracle -v`.
- Builds: 14d85287 and 48f20f2a in fresh detached worktrees, with `zig build` and `zig build oracle`. There was also a trial worktree for the one-line fix below. All three were removed at the end.

## Verdict

**Not safe to land as is. There is one soundness finding (C1), and it is pre-existing: main has it too.**
- **What the PR fixes:** C1 of review 1 is fixed for every subject that is a place, a view a call returns, or a `!E` parameter.
- **What it misses:** one subject kind, `Header.held`, was deliberately left out. That is a read match of a part of a value made in the header, such as `match mk(!p).e`.
  - That kind still binds a write-view payload field as `!T`.
  - `lendTarget` still lends that binding as a read view, with no loan on the binding.
  - So the review-1 shape (`r = ?w.t[1..]`, then `w.t = …`) is accepted, and it is a use-after-free.
  - The PR's new docs state the premise the code breaks. INTERNALS says a read-match binding is "a read view, which no write goes through".
- **Fix:** one line, below. With it:
  - every held probe is rejected;
  - no program in the tree (11,368 under `test/` and `examples/`) changes verdict;
  - the `viewpay.`, `lendw.` and `payload.` matrix families pass.

The rest of the change holds up:
- **Read bindings:** every read binding I built over a place is rejected at the write. That covers named payloads, guards, closures, nested and catch-all matches, generic payloads, a `!E` parameter, a `!WP` local, a field of a `!H` parameter, `if !o as e`, `for x in !v`, and a call returning `!E`.
- **The emit copy (`.*`):** it matches what the checker models. I found no way to write the original while the copy is live.
- **Over-rejection:** I found one more newly rejected valid program shape (M1), and it has an alternative.

---

## Critical

### C1. A read match of a held part of a made value still binds a write-view field as `!T`, so a path write through it is accepted (pre-existing; main the same)

**Minimal program:** `b01_held_part_path_write.rig`.

```rig
struct P
  t: Text

enum WP
  a(w: !P)
  b

struct H
  e: WP

fun mk(p: !P) -> H from p
  H(e: WP.a(!p))

sub main()
  p = P(t: Text("hello"))
  match mk(!p).e
    .a(w)
      r = ?w.t[1..]
      w.t = Text("other")
      print(r)
    .b => pass
```

**Observed, on the head and on main:**
- `rig check` accepts it.
- Debug with `RIG_SANITIZE=1` stops with `use of freed memory`, then signal 6.
- `--release` prints `\0\0\0\0`.
- The oracle reports `DIFF … main prod=accept ref=reject C4 19:7 cannot write `w` while a read loan of it is live`.

**Expected:** a rejection at line 19, as for the same program over a local `e` (review 1's `r16`, now rejected).

**Cause.**
- **Typecheck.** `readsHeldWriteViews` (`typecheck.zig`, about line 2852) returns false for `headerOf(match) == .held`. So `bindPayload` keeps `w: !P` for such a match.
- **Ownership.** `walkMatch` gives the binding a root: the hidden var that holds `mk(!p)`. So `payload_view` is true and `payload_writes` is false, and `lendTarget` returns `.read_view`.
  - `r = ?w.t[1..]` therefore takes no loan on `w`.
  - The path write `w.t = …` finds no loan.
- **The inconsistency.** Typecheck already treats this binding as a read binding:
  - `!w.push(…)` and `!w.put(…)` are rejected with "`match mk(!p).e` reads `mk(!p).e`, and so do its bindings" (`c02`, `n04b`);
  - `w = 5` is rejected the same way (`c07`).

  Only path writes get through. That is exactly C1's original state, for this one header kind.

**Every probe in the class.** All are accepted on both commits.

| Probe | Payload / form | Debug, sanitizer | Release | Oracle |
|---|---|---|---|---|
| `b01` | `!P`, `w.t = Text(..)` | UAF | NULs | DIFF |
| `b02` | `!P`, `!w.t.add(..)` in a loop | UAF | empty | DIFF |
| `c01` | `![]Text`, `s[0] = Text(..)` | UAF | empty | DIFF |
| `c10` | `!P`, a `|!w|` closure writes `w.t` | UAF | empty | DIFF |
| `o01` | the held part is itself a `!WP` of a place (`H { e: !WP }`, `match mk(!e0).e`) | UAF | empty | DIFF |
| `c05` | `!P`, `r = ?w`, then `w.t = …`: the view shows the new value | prints `other` | prints `other` | DIFF |
| `e12` | a named payload `.a(w: w, v: v)`, `!w.t.add(..)` while `r` lives | runs (`ello q`) | runs | DIFF |

`e12` breaks Core sentence 5 even though this run shows no free.

**What is not affected:**
- The held forms of `if … as` (`c03`) and `for` (`c04`) already bind a read view or reject.
- A held subject reached through a read view, `match get(?h).e` (`b03`), is rejected at the binding.
- A whole write or a whole write lend is rejected (`c02`, `c07`, `n04b`).
- A guard that writes is rejected (`c06`).
- Escaping a view of the held temporary is rejected (`o02`, `i01`).

**Fix: drop the held exception.**

```zig
fn readsHeldWriteViews(self: *Checker) bool {
    if (self.matching == .nil) return false;
    return storage.matchesInPlace(self.ctx, self.matching);
}
```

I built this as a trial on 14d85287:
- Every probe in the table is rejected with the ordinary read-view diagnostic.
- A held read that only reads (`i02`: a struct field, a slice of a Text, an `!Int` in a guard and in an arm) runs sanitizer-clean in debug and `--release`. It prints what the head prints, and emit copies the `!Int` out (`const w = __rig_subject_8.*.a.w.*;`).
- `rig check` over all 11,368 programs under `test/` and `examples/` gives the same verdict on head and trial: no program in the tree relies on the exception.
- With the trial compiler, the matrix results are:
  - `viewpay.`: 142 programs, 98 ran clean, 44 rejected, 0 failed;
  - `lendw.`: 240 programs, 96 ran clean, 144 rejected, 0 failed;
  - `payload.`: 683 programs, 498 ran clean, 185 rejected, 0 failed.
- **The one cost:** a held read match that writes through a path (`match mk(!p).e`, `.a(w) => w.n = 7`) is now rejected. The alternative is `h = mk(!p)`, then `match !h.e` (`i02` runs it). The diagnostic's own hint, `match !mk(!p).e`, is itself rejected with "bind `mk(!p)` to a name first". That is pre-existing.

**Ask, with the fix:**
- Add `b01`, `c01`, `c05` and `o01` as reject cases to `reject/ownership/read_match_write_view_payload.rig`, and keep these probes in the corpus.
- Consider a `read_match_held` binding in the `lendw.` matrix family. It would have caught this.
- Optionally, make `lendTarget` defensive: classify a payload binding by its own type. A `payload_view` var whose type is a write view would then be `.write_view` unless `payload_writes` says otherwise. The catch-all of a `!E` subject is the only other read binding of a write-view type, and it would need its own positive entry. With that change, no future header kind that keeps `!T` can bring this hole back.

---

## High

None.

## Medium

### M1. Unlisted newly rejected program: a nested read match through a write-view enum payload (new in this PR)

**Program:** `f04_nested_writeview_enum_read.rig`. `f04c` has the same shape with a `!Out` parameter.

```rig
struct Q
  t: Text

enum In
  a(q: !Q)
  z

enum Out
  a(i: !In)
  z

sub main()
  q = Q(t: Text("hi"))
  i = In.a(!q)
  o = Out.a(!i)
  match o
    .a(w)
      match w
        .a(k) => print(k.t)
        .z => pass
    .z => pass
```

- **Main:** accepts it. It runs sanitizer-clean and prints `hi`.
- **Head:** rejects line 19 with "cannot bind `k`: it holds a write view, and the matched value is reached through a read view or shared handle, which cannot write".
- **Why it happens:** `w` is now `?In`, so `rejectWriteViewBindings` fires on the inner match. The program only reads. The message is also misleading, since the user wrote no read view or handle.
- **Alternative:** `match !o` (`f04b`) runs and prints `hi`.

**Ask:** add it to the PR's cost table and to `test/oracle/differences` if any copy of it reaches the suite. Or better, in a read match that reads in place (`readsHeldWriteViews`), skip `rejectWriteViewBindings`. The binding is a read view by construction there, so the reason for the rejection ("a second writer") no longer applies. That change would also accept these pre-existing over-rejections, all read-only and all rejected on main as well:
- `b03`, `b05`, `e11`: a match on a call or `?self` method returning `?WP`;
- `d06`, `h05`: a `?WI` / `?WT` parameter;
- `e05`, `e09`: a nested read match, and `if o as e`.

It is a design call, so it is not required for this PR.

## Low

### L1. The path-write diagnostic no longer names `match !e`

- **Before:** on main, a whole write through a read binding says "…; to change the field in place, match with `match !e`". The PR keeps that wording for whole writes.
- **Now:** path writes, and lends that convert, give only the generic read-view message:
  - "cannot assign through a read view (`?T`); take a write view (`!T`) to mutate" (`b07`, `b10`, `e07`, `e08`);
  - "cannot lend to write through a read view `?Int`" (`j06b`).
- **Two hints mislead:**
  - `f = WI.a(w)` says "lend it to write: `!w`" (`j04`, `j06`), and following that hint is rejected next (`j06b`). Main's message pointed at `match !e`.
  - The error for `|!w|` says "capture it with `|?w|`" (`b09b`), which cannot write.
- **Ask:** when the target's root is a read-match binding whose `payloadFieldOf` is a write view, add the `match !e` hint, as `requireBinding` does for whole writes.

### L2. A branch value of a by-value read view is a loan-free copy (pre-existing; not this PR)

- **Probes:** `g04` (`r = match e`, `.a(w) => ?w` for `w: ?Int`, then `x = 5`, `print(r)`) and `g09` (`r = if c` with `?x` else `?d`).
- **Behavior:** both are accepted, and both print the old value, on both commits. The oracle agrees, so this is today's rule for a by-value `?T`: a branch value is a copy.
- **Contrast:** a direct `r = ?x`, then `x = 5`, is rejected (`g08`).
- **Effect:** no memory error. It is noted only because the PR's copy of a `?Int` binding sits next to it. It is consistent with that rule, not caused by it.

---

## Other checks

**The emit dereference (`const w = payload.w.*`) matches the checker.**
- **Copy semantics.** A `?Int` / `?String` / `?(Int?)` binding is a by-value read view, and the checker treats it so. Every way to change the original while the copy is live is rejected:
  - a write to the owner (`d01`, `g01` with `defer print(w)`, `g02` with a `|?w|` closure, `g03` with `r = ?w`, `g07` in a guarded arm);
  - `match !e` inside the arm (`d03`);
  - lending write through a `*S` field (`d02`).
- **Reading after a write.** Across loop passes and rewrites, every read sees the current value: `d07`, `d10`, and `m01` with a generic `G[!Int]`, in debug and `--release`.
- **Cells.** A `!Cell[Int]` payload is not copied (`holdsCellByValue` fails `lendByValue`). `w.set(5)` through the read binding reaches the original (`d08` prints `5 5`). No Cell is forked.
- **Guards and arms agree.** I checked them in the param path, the local path, the hidden-payload path, a guard on a by-value field, and named fields in any order (`d07`, `d09`, `m01`, the behavior test). `.*` appears on every binding of the field (`e.*.a.w.*`, `__rig_payload_4.w.*`).
- **No address of a copy.** `bindsByAddress` cannot be true together with the dereference: `fieldIsPointee` is false for a view field. So `&payload.w.*` is never emitted.

**Read-binding type, all rejected at the write on the head:**
- `b07`: a named payload.
- `b08`: a guard lending `!w.t`.
- `b09b`: a `|!w|` capture.
- `b10`, `m02`, `m03`: a generic `G[!P]` / `G[![]Text]`, local and parameter.
- `b12`, `b15`: a struct holding `!P`, and a `Vec[!P]` payload.
- `e03`: `for x in !v`, then `match x`.
- `e04`: `match !o`, then an inner `match i`.
- `e07`: a `!WP` local `k = !e`.
- `e08`: `match h.e` of a `!H` parameter.
- `e10`: `if !o as e`, then `match e`.
- `b04`: a call returning `!WP`.
- `j01` to `j07`: re-wrapping the binding into a `!P` field, enum, optional, or match value. `j05` (`r: !P = match e … => w`) was accepted on main, as a second copy of a unique write view.

**Subjects that only look made:**
- A literal or call that returns the enum by value is `taken`: the binding owns its write view, and the lend is checked as an owner's (`a01`, `a02`, `a03` are rejected).
- `match +e` is rejected (`b17`).
- `match o ?? WP.b` moves (`k01`).
- `match o?` through a view is rejected (`k03b`).
- `Box[WP]` is rejected (`b13`).

The only hole is `held`, C1.

**Over-rejection sweep.** These run clean on the head, in debug and `--release`, and print what main prints:
- `f01`, `f02`: returning `?w` or `w` as `?Int` from a `!WI` parameter's read match.
- `f03`: returning `?P` and a `String` of it.
- `f06`, `f11`: a `?P` / `?Int` match value.
- `f07`: a `?Text` compared, captured `|?w|`, and cloned.
- `f08`: a `?Int` captured `|+w|` and stored as a `?Int` field.
- `f09`: iterating a `?Vec`.
- `f10`: generic `?T`.
- `f12`: returning a `[]Int`.
- `d04`, `d05`: `!String` and `!Int?` payloads.
- `m04`, `m05`: generic `!String` and `!Int?` payloads.

`f04` and `f04c` (M1) are the only newly rejected shape I found beyond the PR's list.
