# Review 1 of PR #94 (payload-loan), head 310f5ecb, base main 48f20f2a

- Probes: `.git/revamp/r3/review-payload-loan-1-probes/` (90 programs, plus `probe.sh`).
  `probe.sh` runs each probe through head `rig check`, main `rig check`,
  a debug run under `RIG_SANITIZE=1`, a `--release` build and run, and `bin/rig-oracle`.
- Probe families by prefix:
  - `p*`: `match !e` in other contexts (nested, closure, generic, call subject, defer, labeled break).
  - `q*`, `s*`: other binding kinds and lend or write forms.
  - `r*`: read-match bindings of a write-view payload (finding C1).
  - `v*`, `w*`: valid programs, to find over-rejection.
- Builds: both commits in fresh detached worktrees, with `zig build` and `zig build oracle`.
  The worktrees were removed at the end.

## Verdict

**The fix is correct, and safe to land.**
- `lendTarget` changes the verdict for one kind of binding only: a `match !e` binding whose type is a write view.
  Before, such a binding was lent as a read view; now it is lent as a write view.
  Every other var is lent exactly as on main, so the change can only reject more.
  It adds no hole.
- Every `match !e` probe I built is now rejected at the write. That covers:
  - nested in `for x in !v` (`p05`), in a closure (`p06`), and in `if !o as e` (`s05`);
  - generic payloads (`p03`, `p04`), and a catch-all with named fields (`p07`);
  - a field path subject (`p11`), an index subject (`s03`), and a call returning `!E` (`p09`);
  - defer (`p14`), a write capture (`q07`), an index write (`q10`), and a `!T` field of a struct payload (`q12`);
  - a catch-all followed by an inner `match !x` (`s01`), and a generic `?T` pass-through (`s09`).

  Main accepts all of these, and most free memory there.
- The fix also closes two aliasing holes on main that the PR does not mention:
  - two live write lends of one binding (`s02`: `w1 = !t`, `w2 = !t`);
  - a read of the binding while a write lend of it is live (`s06`).
- The `lendw.` matrix family on the head gives 192 programs: 96 ran clean, 96 rejected, 0 failed. The oracle shows 0 differences.
- The new reject and behavior tests pass (`./test/run match_write_payload`: 11 of 11).

**There is one soundness finding (C1). Main has it too, and it sits in exactly the fact this PR classifies.**
- **The PR's premise:** `lendTarget` lends every read-match binding as a read view, "since a write through one is rejected".
- **What actually happens:** for a payload that is itself a write view (`!P`, `!Vec[T]`, `![]T`), typecheck rejects only a write to the whole binding (`w = …`, `!w.add(…)`). A write through a path of the binding is accepted: `w.t = …`, `w[0] = …`, `!w.t.add(…)`, `!s[0].push(…)`.
- **Effect:** in safe code, a use-after-free under `RIG_SANITIZE=1`, and garbage with `--release`.
- **The oracle:** it flags most of these, but misses the two-match form (M2).
- **Recommendation:** AGENTS says a soundness finding is fixed before the tag. The PR's new INTERNALS paragraph states the false premise, so folding the fix into this PR is better still.

---

## Critical

### C1. A read match's binding of a write-view payload is lent as a read view, but a path write through it is accepted (pre-existing; main the same)

**Minimal program:** `r16_read_match_writestruct_field.rig`.

```rig
struct P
  t: Text

enum WP
  a(w: !P)
  b

sub main()
  p = P(t: Text("hello"))
  e = WP.a(!p)
  match e
    .a(w)
      r = ?w.t[1..]
      w.t = Text("other")
      print(r)
    .b => pass
```

**Observed, on the head and on main:**
- `rig check` accepts it.
- Debug with `RIG_SANITIZE=1` stops with `use of freed memory`, then signal 6.
- `--release` prints NUL bytes.
- The oracle reports `DIFF … prod=accept ref=reject C4 cannot write `w` while a read loan of it is live`.

**Expected:** a rejection at line 14. Two diagnostics would fit:
- `cannot assign to `w.t`: `match e` reads `e`, and so do its bindings; to write through `w`, match with `match !e``. This is the rule `r15` and `q03` already get for a whole write.
- Or `cannot assign to `w.t` while `w` is lent`.

**Cause.** There are two halves.
- **Typecheck.** In a read match, `bindPayload` binds a field whose type is already a view "as it is" (`typecheck.zig` around line 2815). So `w` has type `!P`.
  - The read-match check in `requireBinding` (the `pattern_bound` branch, about line 1418) fires for a whole write.
  - It does not fire for a write through the binding's write view to a path: a field, an index, or a method on a field.
  - Compare `if o as s` over a `(![]Text)?`, which binds `s` as `[]Text` and rejects `s[0] = …` (`r10`, `r11`).
- **Ownership.** `lendTarget` returns `.read_view` for every binding with `payload_view and !payload_writes`. So `r = ?w.t[1..]` carries only the binding's loan on `e`, and no loan on `w`. Nothing then stops the write. INTERNALS ("Lending a binding") says such a write "is rejected"; for paths it is not.

**Every probe in the class.** All are accepted on both commits; "UAF" means `use of freed memory` under the sanitizer.

| Probe | Payload / form | Debug, sanitizer | Release | Oracle |
|---|---|---|---|---|
| `r16` | `!P`, `w.t = Text(..)` | UAF | NULs | DIFF |
| `r21` | `!P`, `!w.t.add(..)` | UAF | empty | DIFF |
| `r20` | the same, as a bare `match e` of a `!WP` parameter | UAF | empty | DIFF |
| `r14` | `!Vec[Text]`, `w[0] = Text(..)` | UAF | empty | DIFF |
| `q04b` | `![]Text`, `s[0] = Text(..)` | UAF | empty | DIFF |
| `q04c` | `![]Text`, `!s[0].add(..)` | UAF | empty | DIFF |
| `r19` | `![]Vec[Int]`, `!s[0].push(i)` | UAF | prints `[0]` | DIFF |
| `r13` | `![]Text`, `!s[0].clear()` | garbage | garbage | DIFF |
| `q04`, `r01` | `![]Text` / `![]Int`, whole element: the view shows the new value | changed value | changed value | DIFF |
| `r07` | `![]Text`: the view leaves a first `match e`, and a second `match e` writes | UAF | empty | **silent** |
| `r22` | `!P`: the same two-match form | UAF | empty | **silent** |
| `r23` | `!P`: a write through a read match, no lend | runs ("other") | runs | silent |

`r23` is not itself a use-after-free. It shows the root cause: a `match e` that reads `e` writes through it. `r07` and `r22` show why fixing `lendTarget` alone is not enough. Two read matches each hold a copy of the same unique write view. One makes a view through its copy, and the other writes through its own.

**What is not affected:**
- `r02`, `r26`, `q13`: a write view reached through a struct field of a read binding (`h.w.t`, `h.s[0]`) is rejected, with "through a read view".
- `r03`, `r04`, `r06`: `match ?e`, a `?WS` parameter, and a read catch-all are rejected at the binding.
- `r05`, `r24`: a read `for` is rejected.
- `r10`, `r11`, `r25`: a read `if … as` is rejected.
- `r15`, `r17`, `q03`: a whole write is rejected.

**Fix, preferred:** in a read match, bind a field that is a write view as the read view of what it views, as `if o as s` does: `!T` → `?T`, and `![]T` → `[]T`.
- Then every path write through the binding is rejected by the ordinary read-view rule.
- `lendTarget`'s `.read_view` for read-match bindings then becomes true by construction.
- Two read matches can no longer alias a write view.

**Fix, alternative:** extend `requireBinding`'s `pattern_bound` read-match check to accesses with `steps > 0` that go through the binding's own write view. Without a type change, `r07` and `r22` need their own check.

**Also add** a `lendw.` matrix binding `read_match` over `!P`, `!Vec`, and `![]T` payloads, written through a field, an index, and a method on a field. Every cell must be rejected at the write.

---

## High

None.

## Medium

### M1. Unlisted over-rejection: returning a view of a `match !e` binding from a function (new in this PR)

The PR lists v09, v12, and n33 as the cost. A fourth shape is newly rejected, the accessor. Main accepts each of these, and each runs sanitizer-clean on main.

```rig
enum E
  a(t: Text)
  b

fun get(e: !E, d: !Text) -> !Text
  match !e
    .a(t) => !t
    .b => !d
```

- `v01` (`-> !Text`, `.a(t) => !t`): `t` does not live long enough. Main prints `hello!`.
- `v08` (`-> ?Text`, `.a(t) => ?t`): the same error. Main prints `hello`.
- `v02` (writes `!t.add("!")`, then returns `?t[..3]`): the same error. Main prints `hel`.
- The oracle reports `stricter … prod=reject ref=accept` for all three. These are not in `test/oracle/differences`. If any reaches a suite program, the oracle run reports it.

**This is consistent with the existing rule.** `if !o as t` → `return !t`, and `for t in !v` → `return !t`, are rejected on main too (`w05`, `w07`, with "cannot return a view of `t`, which this function was not lent").

**Alternatives:**
- For `v08` and `v02`, a read match works: `match e` with `.a(t) => ?t` (`w06` runs).
- For `v01`, returning a write view of a payload, I found no written alternative. The arm-escape follow-up ("carry the loan onto the binding's held loans") would accept it.

**Ask:**
- Add these to the PR's cost table and to `test/oracle/differences` (`prod-strict`), with the migration line for `v08` and `v02`.
- State that `v01` has no alternative until the follow-up lands. That makes the follow-up more than optional.

### M2. The oracle accepts the two-read-match aliasing of C1 (pre-existing)

- **Probes:** `r07` and `r22`. `rig-oracle -v` says `ref=accept` for both, and both are a use-after-free.
- **Why it matters:** the oracle catches every one-match form of C1, but not a view that leaves one read match while another writes through its own copy of the write view. So the oracle cannot be relied on to find this class.
- **When it matters:** this only bites once C1 is fixed in a way that still allows the aliasing.

## Low

### L1. A `defer` write through a write-view binding is rejected even when it runs after the view's last use (pre-existing class; new for `match !e`)

```rig
  match !e
    .a(t)
      defer !t.add("x")
      s = ?t[1..]
      print(s)
    .b => pass
```

- **Head:** rejects line 9 (`p15`), with "cannot lend `t` to write while a read loan is live". Main accepts it, and it is sound.
- **The oracle:** `stricter`.
- **The same on main for a `!T` parameter and `if !o as t`** (`v15`, `v15b`). So this follows from the existing rule.
- **Workaround:** move the write after the last use.
- **Ask:** at most a line in the PR's cost list.

### L2. A view carried across loop iterations of `match !e` (pre-existing; main the same)

- **Probe:** `v10`. The oracle says `stricter`.
- **Status:** not caused by this PR. Noted only because it showed up in the sweep.

---

## Other checks

**`storage.matchMode` and `payload_writes`.** These are one decider, and emit agrees.
- `decideMatchMode` returns `.write` exactly when the subject is syntactically `!x`.
- The checker reads it through `writesSubject`. Emit reads it through `facts.matchMode`, and binds by address through `storage.payloadByAddress(…, matchMode == .write, …)`.
- `writesSubject`'s fallback without sema (`subject.isKind(.write)`) is the decider's own first line.
- `payload_writes` is set only where `payload_view` is. `lendTarget` additionally requires `ref == .write`.
  - Typecheck gives every non-view, non-slice field of `match !e` the type `!T`.
  - It gives a view field its own type.
  - So a `match !e` binding with `ref == .none` and `payload_view` cannot occur, except a poison type.
- A `![]T` payload is a `write_view` of a slice, so `ref == .write`; the `write_slice_payload` test confirms it.

**The `test/run` harness change** (`find "$RESULTS/st" -type f -exec cat {} +`). It can neither miss nor double-count results.
- Every writer to `st/` writes the flat path `st/${id//\//__}`, so there are no subdirectories for `find` to recurse into.
- No id starts with `.`, so `find` sees the same set as the old glob, which skipped dotfiles.
- Every record ends with `\n`, so batching `cat` cannot join two lines.
- Order is irrelevant, because the output is sorted.
- `2>/dev/null` hides a `find` error exactly as it hid a `cat` error before. If nothing is read, the empty file still reports "no test ran".

**Sibling binding kinds rechecked on the head.** Each is rejected at the write:
- `match <e` with a write-view or Vec payload (`q01`, `q02`);
- moving out of a binding (`q05`), and a bare call through it (`q06`);
- a catch-all reassignment (`q08`), and an inner read match reassigning its subject (`q09`);
- `while !o as w` re-entry (`p12`);
- a labeled break out of an arm with a live view (`p13`, now L3).

`match !h.e` on a `*H` is rejected by typecheck (`s04`).
