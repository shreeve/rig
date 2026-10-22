## Summary
One fact decides whether a write can go through a binding. It is called the binding's **access**: `.write`, `.read`, or none for a binding that owns or copies its value. The fact is decided once, by `sema.decideBindingAccess`. Typecheck derives the binding's type from it, ownership derives the loan a lend of it makes, and storage and emit derive how it is bound.

This is a redesign. Three review rounds each found a Critical use-after-free at a point where two deciders disagreed:
- **C2 (review-syntax-b-2):** a lend of a `match !e` payload binding put no loan on the binding. So `s = ?t[1..]`, then `!t.add(…)`, then `print(s)` read freed bytes. Even `r = ?t; !t.add(…)` passed, which breaks Core sentence 5.
- **C1 (review-payload-loan-1):** a read `match e` bound a payload field that is itself a write view (`!P`, `!Vec[T]`, `![]T`) as that write view, while ownership lent it as a read. A write through a path then passed: `w.t = …`, `w[0] = …`, `!w.t.add(…)`. Two read matches could also each hold a copy of one write view.
- **C1 (review-payload-loan-2):** the same, for a read match of a part of a value made in the header (`match mk(!p).e`). The r1 fix exempted that case (`.held`).

The second round was a second soundness round under AGENTS.md, so the feature stopped and was redesigned as below. Head 14d85287 is tagged `payload-loan-r1`. Main has all three holes.

Review 3 found no soundness hole in the redesign: 912 grid programs across 38 binding kinds. It found one more place where two deciders disagreed, this time about the binding's type (H1). `if o as x` built the type of a read binding of a `(!T)?` with its own helper (`?!T`), while matches used `viewOfAccess` (`?T`). The result was Zig that does not compile (`|?x|`, `[x]`); main has the same root, so `print(y.t)` fails there too (H2). It also rejected reads with no alternative (M1). Every binding's type now comes from its access through one helper, and a check run after typecheck in debug and test builds fails on any binding whose type its access does not give.

Review 4 found two Critical use-after-frees in the header side of the same fact, and both are fixed here.
- **C1 (new in r3's L1):** a read match wrote through a subject whose type was a write view that is not storage. That was a "not X" rule. It let a branch, `?`, `??` or `catch` with a *place* leaf write through a read view, a handle, or a copy of a write view.
- **C2 (on main):** a read match of a branch that reads a place holding a write view copied the write view out of the place with no loan on it.

Both now go through two shared deciders in sema, used by `match` and `if … as` alike:
- **`sema.makesWriteView`** decides when a header lends on a write view, by a positive list: the subject is a write lend `!x`, or a value of a write view type whose every leaf (`yieldedLeaves`) is a write lend, a call's result, a write view taken with `<w`, or a jump.
- **`sema.headerCopiesWriteView`** decides when a header copies a write view out of a place: a branching subject (`a if c else b`, `a ?? b`, `e catch h`, `e!`, `e?`) with a leaf that is a place, or a part of one, of a type that holds a write view. Typecheck rejects it, and the hint names the alternative.

| Written (accepted on main, now rejected) | Write instead |
|---|---|
| `.a(t)`, `s = ?t[1..]`, `!t.add(x)`, then `print(s)` | use `s` before the write, or lend after it |
| `match e` with `.a(w) => w.t = v`, for `w` a write view the payload holds | `match !e`: `.a(w) => w.t = v` |
| `match mk(!p).e` with `.a(w) => w.n = 7` | `h = mk(!p)`, then `match !h.e`: `.a(w) => w.n = 7` |
| `.a(t) => s = keep(?t[1..])` in a `match !e`, with `s` used after the match | write in `match !e`, then take the view in a read `match e`: `.a(t) => s = keep(t[1..])` |
| `.has(p) => w = !p[0..1]`, with `w` written after the match | write through `p` in the arm: `.has(p) => p[0] = 3` |
| `fun head(e: !E) -> String`, `match !e`, `.a(t) => ?t[..3]` (also `?t`) | a read match: `match e`, `.a(t) => ?t[..3]` |
| `fun get(e: !E, d: !Text) -> !Text`, `match !e`, `.a(t) => !t` | none until the follow-up below |
| `match o` with `.a(r) => r`, returning the `!Int` a `!G[!Int]` parameter's payload holds | `match !o`: `.a(r) => r` |
| `s = ?p.t[1..]`, then `!p.xs.push(1)`, then `print(s)` (another field of a `match !e` binding) | use `s` first, or lend after the push: a loan is per binding, as for a local or a `!P` parameter |
| `defer !t.add(x)` in a `match !e` arm, before `s = ?t[1..]` (L1) | write at the arm's end instead of in a `defer`, as for a `!T` parameter or `if !o as t` |
| `if o as x` of a `(!P)?` place, then `x.t = v` | `if !o as x` |
| `match (a if c else b)`, `match o?`, or `match o ?? !d`, with `a`, `b` or `o` holding a write view (review 4's C2: a copy of the write view with no loan) | lend each leaf to write, `match (!a if c else !b)`; for an optional, `if !o as x`, then `match !x` |

The first three rows are unsound on main. The others are the cost on valid programs. A view of a `match !e` binding now stays in its arm, as one of an `if !o as w` binding already stays in its `if`. So it cannot be returned (`if !o as t` and `for t in !v` already return this way on main).

**Newly accepted.** Each runs sanitizer-clean in debug and `--release`, and prints the right value:
- **Read-only, through a read view or handle:** a read match of a payload that holds a write view, as in review 2's M1 (`f04`, `f04c`, `d06`, `e11`). Main rejected these with "cannot bind `k`: it holds a write view". Each now binds the read view, so there is no second writer. (Corpus `review-b4b-2-p68`, a branch over two `W` locals each holding a `!Int`, was accepted in r3. It is rejected again, as on main, by C2's rule.)
- **A write view the subject makes is lent on, as `if … as` lends one on (review 3's L1, made a positive list in review 4).** The subject is a call's result (`match get(!h)`), or a branch whose every leaf is a write lend, a call's result, or `<w` (`match (!a if c else !b)`, `optw(!e) ?? !d`, `tryw(!e) catch !d`), and its bindings write. Main rejected writing through them with "cannot assign through a read view". This makes four corpus probes run, among them `review-step45-r2-b06` and `review-step3-r2-g18`, keeps review 3's `l06` and `l08` running as on main, and turns `copies_match_made_write_view.rig` from a reject test into a behavior test.
- **H2, which fails in Zig on main:** a read `if o as x` or `while o as x` of a `(!T)?` local, field, handle or parameter, with `print(x.t)`, `|?x|`, `[x]`, `show(x)`, `total(s)`, `k + 1`, `m: Int = k` or `|+k|` (`m01`, `m03`, `m04`, `n02`, `n22`, `n23`).

## Design
- **The fact.** `Symbol.access: ?sema.Access` holds the access, and `SemContext.bindingAccess(sym)` reads it. A parameter or local has no recorded access; it is given by its type, through the decider's own `declared` entry.
- **The decider.** `sema.decideBindingAccess(site)` works by a positive list over every kind of binding (`BindingSite`):

  | Binding | `.write` | `.read` | none |
  |---|---|---|---|
  | a parameter, local, or closure capture | its type is `!T` or `![]T` | its type is `?T` | any other type |
  | `if … as x`, `while … as x` | `!o`, or a write view the header makes | a value viewed where it is, or reached through a read view or handle | a copy, or a value taken (then by its type) |
  | `for x in` | `!v` | an element that does not copy | an element that copies, or one taken (then by its type) |
  | a `match` payload, named field, or catch-all | `match !e`, or a write view the subject makes (a call's result, or a branch of write lends), of a field that is no read view or slice; a write view field of a value the match holds whole | a read match of anything else, whatever its subject: a place, a lend, a read view a call returns, a part of a value made in the header; a `?T` field | plain data a read copies; a slice; `match <e` (then by its type) |

  `MatchReach` (`written`, `read`, `read_own`, `owned`) is how a match reaches its subject. `matchReach` decides it by a positive list:
  - `.written`: `match !x`, or a subject `sema.makesWriteView` accepts;
  - `.owned`: `match <x`, or a value made there that owns;
  - `.read_own`: a value made there (`hands` is `.made`) whose type is an enum, an error, an integer or a Bool, which the match holds whole (`match wrap(!x)`). Such a match owns the write view its payload holds, so returning it still works;
  - `.read`: anything else.
- **"Not X" logic converted to positive lists (review 4's ask).** Every condition in `matchReach`, the header deciders and `decideBindingAccess` was audited. Four were negative, and each is now a positive list:
  1. `matchReach`'s `.written`, "a write view type and `!hasStorage()`" (review 4's C1), is now `sema.makesWriteView`.
  2. The `as` path's `.written`, `writes and !hasStorage()`, the same rule, is now `sema.makesWriteView`.
  3. The `as` path's `.read` for a view inside an optional, "the outer type is `!= .write_view`", now reads "the outer type is `.read_view` or `.shared`".
  4. `matchReach`'s `.read_own`, "a made value whose type is not a view", now lists the made value's types: an enum, an error, an integer or a Bool.

  Every remaining default falls to the safe category:
  - `.read` in `matchReach`;
  - none (an owner) in `decideBindingAccess`'s declared entry;
  - `.owner` in `lendTarget`.
- **The structural test also pins** that `sema.makesWriteView` and `sema.headerCopiesWriteView` are each called from exactly two functions in typecheck: `matchReach` with `checkOptionalBinding`, and `checkMatch` with `checkOptionalBinding`.
- **Typecheck derives the type from the access, never the other way round, through one helper.** `viewOfAccess(access, reached)` gives a write view of what the binding reaches, or a read view of it (`!T` read as `?T`, `![]T` as `[]T`), or the value itself. It is the only code that builds a binding's type from its access, and every kind of binding uses it:
  - **Matches:** `bindMatchView` serves payloads, named fields and catch-alls.
  - **`as`:** `checkOptionalBinding` classifies the reach, then calls `asAccess`.
  - **Loops:** `checkFor` uses `loopElement`, through `writeElement`, `readElement` and the take paths.
- **The type and the access are checked against each other (L3).** `sema.checkBindingAccess` runs after type checking in debug and test builds, so in the suite, the corpus, the matrix and the unit tests. For every binding whose access typecheck decided (`SymbolFlags.access_decided`) it checks:
  - `.write` has a write view;
  - `.read` has a read view, a slice, a String, or a type parameter's value read in place;
  - none has a value.

  Anything else is an internal error at the binding. A helper drifting, or a binding kind typed some other way, fails loudly. I confirmed this by breaking `viewOfAccess` on purpose: `n01c` reports "internal error: binding `x` has type `!P`, which its access (read) does not give".
- **Ownership derives the loan from the access.** `lendTarget(v)` reads `ctx.bindingAccess(v.sym)` and nothing else:
  - `.write` puts a loan on the var, plus the loans it holds;
  - `.read` carries only the loans it holds;
  - no access means an owner, which takes a loan on the var. Hidden vars and checks without sema are owners.
- **Storage and emit read the same fact.**
  - `payloadByAddress` binds a payload by pointer for `.write`, where it used to use `matchMode == .write`.
  - `Facts.readsThroughWrite(sym, reached)` decides how emit binds a `.read` binding of a write view: the write view itself (`?P`, `[]T`), or for a scalar or view the value it points at, copied out. That covers match payloads in arms and guards (`payloadReadsThroughWrite`, `const w = payload.w.*;`), and `as` bindings in all three header paths: viewed in place, read through a view, and captured directly.
- **A unit test checks the structure** (`typecheck.zig`, "a binding's mode is decided once, by decideBindingAccess"):
  - `sema.decideBindingAccess(` appears exactly three times in typecheck, inside `loopElement`, `bindMatchView` and `asAccess`;
  - the access is recorded, and marked decided, at exactly three sites;
  - `viewOfAccess` is called exactly three times, from `checkOptionalBinding`, `loopElement` and `bindMatchView`, and no `asBindingType` remains;
  - the decider is defined once, in sema, and no other pass calls it or records the fact;
  - ownership reads the fact once, inside `lendTarget`, whose body reads no `.ref`, `payload_view`, `matchMode` or type;
  - `payload_writes` and `writesSubject` are gone;
  - `payloadByAddress` reads the access, not `matchMode`.
- **Diagnostics follow the access (review 2's L1 and review 3's L2).** A write through a read binding names what writes (`readMatchHint`, `writeMatchAdvice`). This applies to path assignments, write lends, slice writes, `|!w|` captures, and type mismatches where a write view goes, for every subject:
  - a place: "match with `match !e`";
  - a part of a value made in the header: "bind `mk(!p)` to a name first, then match its part with `match !`";
  - `o?`: "lend the value inside to write first, `if !o as x`, then match it with `match !x`";
  - a branch: "lend each branch to write";
  - a call returning a read view: "match a write view instead";
  - any other value: bind it to a name first;
  - `if o as x` of a place: "bind it with `if !o as x`".

  These replace the misleading "lend it to write: `!w`" and "capture it with `|?w|`". `read_binding_write_hints.rig` follows each hint to a program that runs.
- **No Core change.** Sentences 5 and 7 decide every case.
- **Docs match the code (M2):**
  - SPEC states which read matches lend on a write view (a call's, a branch of write lends), that every other read match never writes through its bindings whatever its subject, and how to write instead;
  - INTERNALS "Binding access" has the table, the one helper, the agreement check, emit's binding of both match and `as`, and the desugaring.

## Deleted
- `Var.payload_writes`, `Checker.writesSubject` and `Scrutinee.writes` in ownership; `lendTarget` no longer reads `payload_view` or `ref`.
- `readsHeldWriteViews`, and with it the `.held` exception, plus `readViewOfWrite`, in typecheck.
- `asBindingType`, the `as` path's own type helper (review 3's H1).
- `rejectWriteViewBindings` and its `read_only` test in `checkMatch`. A read match's bindings are read views by construction, so the "second writer" it guarded against cannot occur. That is what makes M1's programs run.
- `payloadByAddress`'s `writes` parameter, which came from `matchMode`.

`payload_view` stays. It is a different fact: whether a binding owns what it binds, for moves and drops. It is not whether a write may go through it.

## Siblings checked
- **Write bindings, already loaned on main:** `if !o as w` (also on a `!T?` parameter and a payload's optional), `while !o as w`, `for x in !v` and a field of its element, a `!T` parameter, a `|!t|` capture, a held `w = !t`, a field of a write view, a `![]T` local or parameter, `match <e`, and `match !get(!h)`.
- **Fixed here, `match !e` bindings:** every subject (local, parameter, Box, held, field, index, a call returning `!E`); nested, named, catch-all and generic payloads; `![]T` and `!T` payloads; and every lend form (slice, whole, argument, bare slice argument, `|?t|`, `for` source, `if … as`, stored, pushed, optional, `?self` method).
- **Fixed here, read bindings of a write view:** every read-match subject, a held part included (`b01`, `b02`, `c01`, `c05`, `c10`, `o01`, `e12`); a guard; a closure; nested and catch-all matches; generic payloads.
- **Also fixed: `if o as s` over a `?((![]T)?)`.** On main the binding is a write view reached through a read view, and `s[0] = …` was accepted. Reached through a read view or handle, it is now `.read`. Main accepts `sub f(o: ?(![]Text)?)` with `if o as s` and `s[0] = Text("other")`; this branch rejects it.
- **Every lend site** goes through `lendOn`, so through `lendTarget`: `lendVar` (slices and whole lends), receivers, and `receiverLeaves`.

## Commits
- r1 (tag `payload-loan-r1`, 14d85287): the C2 fix, review 1's C1 fix, the `lendw.` family, the corpus probes of reviews syntax-b-2 and payload-loan-1, the `test/run` harness fix, and the `test/oracle/differences` entries.
- 1080fed1 Decide a binding's access once, and derive its type and loan from it
- 4f058db5 Add held-subject read-match cells to the lendw matrix family
- 4fd21fa6 Keep review 2's payload-loan probes in the corpus
- 3fd52637 Derive every binding's type from its access through one helper, and check they agree
- e1d4d608 Add review 3's binding kinds to the lendw matrix family
- d2a437c5 Keep review 3's payload-loan probes in the corpus
- 21b174a1 Lend on a header's write view by a positive list, and reject a branch that copies one out of a place
- 19e1e422 Add the branch subjects that copy or lend a write view to the lendw family
- e7041212 Keep review 4's payload-loan probes in the corpus
- d73cebf6 Lend on a write view a header takes with <w, as one it makes

## Tests
- **Reject tests** in `reject/ownership/`:
  - `match_write_payload_lent.rig`: 22 errors, every `match !e` binding kind, payload type and subject, each with an `# oracle: … reject C4` line;
  - `match_write_payload_lent_forms.rig`: 7 lend forms;
  - `read_match_write_view_payload.rig`: 20 errors, each with its hint. These are every review shape of a read binding of a write view: field, method, `!WP` parameter, Vec index, slice index, `add`, `push` and `clear`, an Int element, a whole `!Text`, two read matches, a write with no lend, every held shape (field, method, slice, whole lend, closure, a part that is itself a `!WP`, named fields), and a rewrap that gets the `match !e` hint;
  - `read_binding_write_hints.rig`: 8 errors, one per subject kind. Each hint is followed to a program that runs, including the two review 4 found misleading: a by-value parameter `o` is "taken to write (`o: !…`)" first, and a subject reached through a read view says nothing writes through it;
  - `match_branch_copies_write_view.rig`: 9 errors, each of review 4's C1 and C2 shapes. These are fields through a read view and through a handle, a call beside a field, bare write views (also written through the source while a view lives), a write view beside a lend, `o?` and `o ?? !d` of a `(!E)?`, `h.o?` through a read view, and an `as` of a branch of read-view fields.
- **Behavior tests** in `behavior/ownership/`:
  - `match_write_payload_lend_ends.rig` (`# release`): lends and writes that do not overlap;
  - `read_match_write_view_payload_reads.rig` (`# release`): reads through `!P`, `![]Int`, `!Int` (in an arm and a guard) and `!Vec[Int]`, a made value returning its write view, and `match !o`;
  - `read_match_held_and_nested_reads.rig` (`# release`): a held read, the held write written as `h = mk(!p)` then `match !h.e`, a held `!Int` in a guard, a `?WI` parameter, a `?self` method's view, and M1's nested read match, both local and through a `!Out` parameter;
  - `as_read_write_view_value.rig` (`# release`): every H1, H2 and M1 shape of review 3. A read `if`/`while … as` of a `(!P)?`, `(![]Int)?`, `(!Int)?` or `(!Text)?` (a parameter, a local, a field, a handle) is read, captured `|?x|` and `|+k|`, put in an array, passed to `show(x)`/`total(s)`, used as `k + 1` and `m: Int = k`, and written as `if !o as w`;
  - `match_made_write_view_lent_on.rig` (`# release`): a match of a call's write view, a branch of write lends, a nested branch, `catch !d`, `?? !d`, and a branch of `<w`, written through. It was `reject/ownership/copies_match_made_write_view.rig`.
- **Updated:**
  - `write_view_in_payload.rig` writes with `match !s`;
  - `match_view_subject_misuse.rig` and `write_view_copied_by_binding.rig` expect the new read-view messages, each naming `match !…`.
- **Matrix:** `lendw.` now has 1,368 programs over 54 binding kinds. These are:
  - review 3's grid generator folded in, with its two malformed kinds fixed (`for_index`, `if_as_write_param`);
  - `match_call_lent_on` and `match_branch_lent_on` for L1;
  - review 4's C1 shapes, written through the binding: a branch of read-view fields, `??` of a read-view field, a branch of handle fields, a call beside a field, bare write views, and `??` of an optional write view;
  - its C2 shapes, written through the place the branch copied from (a `via` write): bare write views, a write view beside a lend, and `??` of an optional write view.

  The types are Text, Vec, `Box[Text]` and a struct with a Vec. The lends are whole, slice, and call or method, followed by a write while the view is live or after.
  - **This branch:** every `live` cell of the 30 write kinds and every cell of the 24 read and copy kinds is rejected (1,008). The 360 `after` cells of the write kinds run clean, printing what the view showed and what the write left.
  - **Main's compiler fails 48 of the 72 C2 cells** (16 use-after-free, 32 printing what they should not).
  - **Main's compiler fails 42:** 24 `match` cells (16 use-after-free, 8 printing the changed value), 12 `read_match` cells, and 6 `read_match_held` cells.
- **Corpus:**
  - every review probe:
    - review-syntax-b-2: 161 of 165 (the parser-only `a10`, `a21`, `b22` and `d11` are left out);
    - review-payload-loan-1: 90;
    - review-payload-loan-2: 116;
    - review-payload-loan-3: 119 of 120 (the parser-only `e04` is left out);
    - review-payload-loan-4: 97, plus `j01_modules`. The parser-only `a06` and `d07` are left out. So are `i01`, `i02`, `i04`, `i05` and `i07`, review 4's M1 and M2 probes, which fail in Zig on main too (Follow-ups).
  - each is rejected, or runs sanitizer-clean.
- **Unit:** the structural test above.

## Survey: newly rejected programs in the tree
`test/equiv.py` against 48f20f2a: 335 of 11,625 programs differ.
- **Emit differs in 32 programs that both compilers accept:**
  - **23 print the same on both** under `RIG_SANITIZE=1`. In each, a read binding of a write view is now its read view.
  - **9 fail in Zig on main and run now:** review 3's H2 probes `m01`, `m03`, `m04`, `n02`, `n22`, `n23` and `l07`, and review 4's `h07` and `h09`.
- **Every other program both compilers accept emits identical Zig and an identical package.**
- **Rejected on both (151):** the message changed, now naming what writes, or rejecting a header that copies a write view.
- **Newly rejected (79):** all are new tests and review probes but one, `review-assign-desugar-n33`. That one is the sound arm escape in the migration table.
  - **Use-after-free on main:**
    - review syntax-b-2: `m01`, `m02`, `m04`, `m05`, `m06`, `m09`, `m10`, `m13`, `m14`, `m15`, `b02_arg`;
    - review payload-loan-1: `p04`, `p05`, `p06`, `p07`, `p11`, `p14`, `q04b`, `q04c`, `q07`, `q10`, `q12`, `r07`, `r14`, `r16`, `r19`, `r20`, `r21`, `r22`, `s03`, `s05`;
    - review payload-loan-2: `b01`, `b02`, `c01`, `c10`, `o01`;
    - review payload-loan-4's C2: `k01`, `k03`, `k05`, `k06`, `d01`;
    - and review 3's C1 and C2 grid shapes.
  - **Core violations without a free:** a view live across a write through its binding, two write lends of one binding, a write through a read binding, a second copy of a unique write view, or a write view copied out of a place (review 4's `a05`, `k02`, `k04` and others).
  - **Sound, each in the migration table:** the arm escapes `v09`, `v12`, `n33`; the returns `v01`, `v02`, `v08`; the defer `p15`; the other field `v06`. These are listed in `test/oracle/differences` as `prod-strict`.
- **Newly accepted (30):** each runs sanitizer-clean in debug and `--release`, and prints the right value. Review 4 checked the 19 newly accepted programs it listed; all but `review-b4b-2-p68`, rejected again as noted above, still run.
  - **Pre-existing corpus programs, now lent on (L1):** `review-step3-r2-g18`, `review-step45-r15d`, `review-step45-r2-b06`, `review-step45-r2-c03`;
  - **review probes and new tests:** read-only reads through read views, `as` bindings of write views, and write views a call or a branch of lends makes.
- **Matrix:** `viewpay.write.write_param.ret` is newly rejected; its alternative, `match !o`, is in the table.
- **Oracle:**
  - **review 3's probes:** six `stricter` lines, all rejected on main too, classified in `differences`:
    - four `prod-strict`;
    - two `ref-gap`, where the oracle accepts a use-after-free (`f04b`, `j05`).
  - **review 4's probes:** three `stricter` lines, all rejected on main too, classified `prod-strict`:
    - `e15`: a view held across loop passes of a branch of write lends;
    - `n02`, `n03`: a call that may store one write argument's view in another.
  - **No DIFF.** The C1 and C2 probes the reviewer found the oracle silent on (`c01`, `c03`, `l06`, `l07`, `k01`, `k06`, review 4's L1) are now rejected in sema, where the oracle abstains ("a write view seen through a read view or a handle", "a bare value holding a write view handed on"). So they cannot be listed as differences. The oracle's gap remains, and is in Follow-ups.

## Verification
Gates at d73cebf6, all through `heavy.sh` with `--delta` and `RIG_SANITIZE=1`. The binding-access agreement check runs in each, since `bin/rig` is a debug build.
- **Suite:** 3,055 passed, 0 failed, 3 pending.
- **Corpus:** 9,131 passed, 0 failed. This includes every probe of the five reviews but the parser-only and M1/M2 ones.
- **Matrix:** 7,501 programs, 3,820 rejected, 3,681 ran clean, 0 failed.
- **`lendw.` alone:** 1,368 programs, 1,008 rejected, 360 ran clean, 0 failed.
- **Review 4's probes:** every one of the 105 was run.
  - **Rejected:** every C1 and C2 shape (`a02`–`a05`, `a07`, `b01`–`b04`, `c01`–`c03`, `d01`–`d04`, `k01`–`k06`, `l03`–`l07`).
  - **Accepted:** every accepted probe runs sanitizer-clean, except the five M1/M2 probes, which fail in Zig as on main.
- **Unit:** 136 of 137 passed, 1 skipped. The structural test is among them.
- **Oracle:** 5 of 5 sets.
- **equiv:** against 48f20f2a, as above.

## Follow-ups
- **The arm escape (design decision, not taken here):** a view of a write-view binding could outlive the binding. When the binding's scope ends, its loan would be carried onto the binding's own held loans, which already keep the viewed value lent. That would lift the escape rule for `if !o as w`, `while`, `for`, held `w` and `match !e` alike, and accept `v05`, `v06`, `v09`, `v11`, `v12`, `n33`, and the returns `v01`, `v02`, `v08`. The oracle already accepts them.
- **M1 of review 1 makes that follow-up more than optional:** returning a write view of a `match !e` binding (`-> !Text`, `.a(t) => !t`) has no written alternative until it lands. The same is true on main for `if !o as t` and `for t in !v`.
- **Review 4's M1 (on main, not this class):** `for x in v` over a `Vec[?P]` (also `for x in ?rv`), then `x.n`, is accepted and fails in Zig. Emit binds the slot by address while the binding's type is `?P` (`i04`, `i05`, and the generic `i01`, `i02`). `checkBindingAccess` compares a binding's type with its access, not with emit's representation, so it cannot see this.
- **Review 4's M2 (on main, not this class):** in a generic body, a `|?x|` capture of a `match !g` binding fails in Zig for `T = Int` (`i07`).
- **Review 4's L1:** the oracle does not model a write through a read view or a handle in a match subject. The compiler now rejects those programs in sema, where the oracle abstains.
