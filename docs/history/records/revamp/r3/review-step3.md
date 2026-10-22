# Review: REVAMP-3 step 3, "Reads and lends" (`r3-step3`, `911d91c0..5e38370e`)

Independent reviewer; I wrote none of this code. I built HEAD (`5e38370e`) and
the step base (`911d91c0`) from `git archive` in scratch copies, with
`bin/rig-oracle`. Every probe was run with `RIG_SANITIZE=1 bin/rig run`, and
each finding was compared against the step base, and where it matters against
`rig-base` (v0.1.0) and `main`. I ran no suites beyond the `classify` lint (it
passes) and modified no tracked files.

Probes: 160 programs in `.git/revamp/r3/probes/review-step3/`; the key verdicts
at HEAD are in `HEAD-results.txt` there. The round-1 and round-2 step-1 probes
were rerun at HEAD (no crash, no Zig compile error, no leak; details in §6).

## Verdict

The lend table (3.1a/3.1b/3.4) is solid: every row I probed (Vec, `*T`, `X?`,
composed boxes, members through boxes, Text through handles and boxes) emits a
pointer into the owner's slot, never a copy, and its loan sits on the owner's
root binding (`-h`, `h = …`, `<h`, `!b.add`, `-b`, `!v.push` and `o = none` all
conflict). Cell ⇒ unique holds on every copy path I tried. Viewed header
subjects (a bare place) are sound: mutations, moves, drops, guards and
`while … as` re-evaluation are all caught.

Three things are not done:

- **Read-match owner payloads.** They are still emitted as by-value copies
  while the checker and the oracle treat them as aliases of the subject. A view
  of one escapes the arm and dangles (**C1**). This is older than step 3, but
  step 3 was chartered to close it ("bind every type's … read-match payload …
  a view of a place"). CORE sentence 1 now marks "a `match` on a `Box`" read in
  place as *(built)*, which is not true for owner payloads. Step 3 also makes
  the bug reachable through new bare forms: `match b` on a Box, `match h` on a
  `*E`, and implicit argument lends.
- **The `held` class** (a part of a made value) is the weakest part of the step:
  - accepted programs reach an emit internal error, and the oracle's hard gate
    fires (**H1**);
  - accepted plain-data programs change meaning (**H3**): literal patterns are
    rejected and drop order moves;
  - INTERNALS, SPEC, sema and the oracle disagree on what a held payload is
    (**M1**).
- **Implicit lends of a made value** into a call whose arguments are hoisted
  (keyword arguments, or a later argument with `!` or `?`) emit Zig that does
  not compile (**H2**).

Both H1 and H2 sit in the statement-temporary machinery. Neither corrupts
memory today: emit fails closed. But H1 is a checker-side miss of a
header-temporary loan, and only emit's refusal stops it from running. The
design owner should decide whether it counts as the third statement-temporary
slip.

| # | Sev | New in step 3? | Finding |
|---|---|---|---|
| C1 | **Critical** | pre-existing, in charter, wider reach | A read-match owner payload (or a catch-all binding of an owner) is a stack copy in emit, but an alias of the subject in the checker. `?r` escapes the arm and dangles. |
| H1 | **High** | yes (`762bfde6`) | Held header with a temporary inside the held value: `rig check` accepts, emit hits an internal error, and the oracle's hard gate fires. Four base-accepted programs regress. |
| H2 | **High** | yes (`bbf342e2`) | An implicit lend of a made value plus hoisted arguments emits `rig.keep` twice, so the Zig does not compile. |
| H3 | **High** | yes (`762bfde6`) | Held also covers plain data, which changes accepted programs. `match [1, 2][0]` with `1 =>` is rejected. A plain payload's made value is dropped after the arms, not at the header's end. q93b is newly rejected. |
| M1 | Medium | yes | INTERNALS says held payloads are owned (`<_h.f`); code, SPEC and `sema.Header` view them. The oracle sides with INTERNALS. The Core does not imply the held rule. |
| M2 | Medium | no (contradicts new SPEC text) | A taken loop or match binding of a Cell holder cannot be lent (`touch(?k)`, `\|?c\|`), and the diagnostic gives a stale "a copy" reason. |
| M3 | Medium | design | Payload binding has three cases: plain copies, owner aliases (`F`), unique views (`?F`). INTERNALS says the last two are both views in place. This is the exception list behind C1. |
| L1 | Low | | Stale diagnostics and comments (§5). |
| L2 | Low | | The kept corpus probe q93 has an unrelated error that masks the H3 regression. |
| L3 | Low | | The held base is re-derived from syntax in three passes instead of being recorded in the `Header` fact. |
| L4 | Low | | INTERNALS does not say that held is rejected in joined conditions, in value-position `if`, and in `while … as`. |

---

## C1 (Critical): a view of a read-match owner payload escapes the arm and dangles

**Where.** In `typecheck` `checkVariantPattern` (diff hunk at about :2471), a
read payload is `?F` only when `sema.isUnique(F)`. An owner payload keeps type
`F`, and the ownership checker binds it as an alias of the subject (its loans
are on the subject's root). Emit binds it by value:

```zig
switch (e.*) { .a => |__rig_payload_1| __rig_blk_2: {
    const r = __rig_payload_1.r;
    break :__rig_blk_2 &r; } ... }
```

`?r` is then the address of the arm's stack copy. The checker records it as a
loan on `e`, so it may outlive the arm.

**Repro** (`probes/review-step3/o04_owner_alias_return.rig`):

```rig
struct Res
  n: Int
  t: Text

enum E
  a(r: Res)
  b(r: Res)

fun inner(e: ?E) -> ?Res
  match e
    .a(r) => ?r
    .b(r) => ?r

fun clobber(n: Int) -> Int
  a = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]
  b = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]
  a[1] + b[2]

sub main
  e = E.a(r: Res(n: 1, t: Text("hello")))
  x = inner(?e)
  print(clobber(1000))
  print(x.n, x.t)
```

The output is `2003` then `6104785680 ` (garbage `n`, empty Text): a dangling
stack pointer. The sanitizer cannot see it, because the memory is stack, not
heap.

**Siblings, all accepted:**
- `o10`: `match b` on a `?Box[E]` parameter, called bare as `inner(b)`;
- `o12`: `match h` on a `?*E`;
- `o11`: `match ?e`, written;
- `o02`: `saved = ?r` stored to an outer local;
- `o16`: catch-all `x => saved = ?x`, which emits `else => |x| … saved = &x`.

`o15` (catch-all `x => ?x` as a tail) is accepted and then fails in Zig
(`expected *const E, found E`).

Plain payloads are correct ("`p` does not live long enough"). Loop elements and
viewed `if … as` bindings are correct: they are captured by pointer (`o06`,
`o09`, `o14`).

**Status.** The bug is identical at `911d91c0`, at `rig-base` (v0.1.0) and on
`main` with `?e` written. The oracle accepts too (`prod=accept ref=accept`):
it models the payload as a view, which is what the checker walks and not what
emit writes. This is the AGENTS class "the checker checks exactly what is
emitted".

**Fix (class).** Bind every read payload of a type that is neither plain nor a
view through a pointer capture (`|*payload|`, `&payload.f`), as the unique case
already does. This also applies to the catch-all binding of a viewed or written
subject. Then type the binding `?F`, as INTERNALS "Header subjects" already
states, and make emit read the binding's type. The fix is in
`checkVariantPattern` (the `isUnique` test becomes `copyable == .no`),
`bindPayload`, and emit's `payloadAliases` and `emitCapture`.

Tests:
- `o04`, `o10`, `o12`, `o16` as behavior tests that print the right value;
- a reject test where `?r` outlives a payload of a temporary;
- a matrix axis: payload type {plain, owner, unique} × subject {place, `?p`,
  Box, `*E`, held} × escape {return, outer store, closure}.

Until the fix lands, CORE sentence 1's "*(built* … a `match` on a `Box`)" is
false for owner payloads.

## H1 (High): held header with a temporary in the held value

**Repro** (`t10_held_temp_explicit.rig`, `t11_held_temp_plain.rig`,
`t15_for_plain_held_temp.rig`):

```rig
struct H
  arr: [2]Int

fun mkh(s: String) -> H
  H(arr: [s.len, 2])

sub main
  for k in mkh(?Text("abc")).arr
    print("k", k)
```

At HEAD, `rig check` accepts it and `rig run` stops with "internal error:
cannot emit a temporary outside a statement (sema should have rejected it)".
Base (`911d91c0`) prints `k 3`, `k 2`. The same happens for:
- `match mkh(?mkres(1)).e` (t10 and t11; base prints `drop 1 / a 1 …`);
- `if mkh(?mkres(5)).o as c`;
- the implicit forms `mkh(mkres(1))` and `mkh(Text("abc"))` (t08, t09).

**Oracle hard gate.** `t01_held_borrows_temp.rig` passes a temporary to `mkh`,
which keeps the view in the held value (`match mkh(?mkres(1)).e`, payload
`?Res`):

```
DIFF t01_held_borrows_temp.rig main prod=accept ref=reject C5 22:9 a loan of a temporary outlives its statement
```

**Cause.** In `ownership.holdBase` (called from `walkMatch`, `walkFor` and
`walkConditionParts`), the base is walked before the header records its
`drops` mark. The base's statement temporaries are therefore not header
temporaries:
- `dropStmtTemps(drops)` does not end them;
- `header_temps` does not contain them, so the "binding outlives a temporary"
  check never sees them;
- the checker instead lets them live until the enclosing statement ends.

Emit's `emitHeld` writes the held `var` outside any statement slot, so
`tempSlot` finds nothing.

By Core §3 ("A header's temporaries end with the header"), t01 must be
rejected. If emit gave the temporary a statement-level slot, it would run with
a view into the dropped temporary only when the checker models the drop at the
header. As built, the checker and the Core disagree, and only emit's refusal
keeps memory safe.

This is a statement-temporary defect (header temporaries plus `holdBase`). The
brief says a third such slip stops that feature, so the design owner should
rule on it.

**Fix.** Take the `drops` mark before `holdBase` (or make `holdBase` part of
the header statement), so that the base's temporaries are header temporaries:
- they end with the header;
- a binding or held value that keeps a loan on one is reported, as `q90`'s
  class is;
- emit declares their slots in the header's block before `emitHeld`.

Test: t01 as a reject test; t10, t11 and t15 as behavior tests.

## H2 (High): implicit lend of a made value plus hoisted arguments fails to compile

**Repro** (`a11_print_hoist.rig`):

```rig
error Bad
  boom

struct Bag
  n: Int

fun mk(n: Int) -> Bag
  Bag(n: n)

fun val(n: Int) -> Int!
  if n > 5
    return Bad.boom
  n

fun two(a: ?Bag, n: Int) -> Int
  a.n + n

fun run(n: Int) -> Int!
  two(mk(1), val(n)!)

sub main
  print(run(2) catch -1)
```

`rig check` accepts it. Zig then fails with "expected type 'Bag', found
'*Bag'":

```zig
const __rig_arg_3_0 = &rig.keep(&__rig_tmp_1, &__rig_tmp_1_live, mk(1)).*;
...
break :__rig_call_3 two(rig.keep(&__rig_tmp_1, &__rig_tmp_1_live, __rig_arg_3_0).*, ...);
```

The hoisted argument is kept in its slot, and the call site keeps it again.

The same failure occurs for:
- keyword arguments in another order: `two(b: mk(2), a: mk(1))` (a06);
- a later `?` argument (a07);
- a method with a later failing argument: `b.plus2(mk(1), mkf(n)!)` (a10);
- `two(mk(1), ?mkf(n)!)` (a03c).

These are new with 3.2. Base rejected them as type mismatches, and the
explicit spellings (`?mk(1)`, `b: ?mk(2)`) run correctly at HEAD (a03b,
a06b). Positions without hoisting work and drop correctly:
- `return`, a tail, `break v`, a value `if`, `catch`, `??`;
- a `while` condition and step, a guard, `defer`, `and`/`or`, a ternary
  (a01, a02, a05, a09).

**Fix.** The hoist path and `emitLend`'s implicit row-less branch must agree on
who writes the `rig.keep`. Emit the hoisted value through the same lend once,
and pass the hoisted name as the view. This touches `rig.keep` and `tempSlot`
use, which the brief reserves; report it as such. Test: a06, a07, a10 and a11
as behavior tests, plus a matrix axis "implicit made lend × {keyword reorder,
later `!`, later `?`, receiver}".

## H3 (High): held changes the meaning of accepted plain-data programs

`checkMatch` records `Header.held` for every part of a made value. It then
interns `?reached` as the scrutinee type, whatever the type is, so plain data
is viewed too. `checkFor` likewise records held for plain arrays. The feature
freeze allows only rejections to become acceptances. These are the reverse,
plus a silent change.

1. **Literal patterns are rejected** (`t16_match_lit_parts.rig`; base prints
   `one / four / gt / k 4 / three`):

   ```rig
   struct P
     n: Int

   sub main
     match [1, 2][0]
       1 => print("one")
       _ => print("other")
     match P(n: 3).n
       3 => print("three")
       _ => print("other")
   ```

   HEAD reports "type mismatch: expected `?Int`, got `Int`" at each literal
   arm. The same root cause makes `match b` on a `Box[Int]` report `?Int`
   (t17), which is still a rejection, so it is low.

2. **Drop order moves** (`d01_drop_order.rig`): `H` holds a `Noisy` with a
   printing `drop`, and `match mkh(3).e` has a plain payload `.a(n)`. Base
   prints `drop 3`, `arm 3`: the temporary ends with the header, per Core §3.
   HEAD prints `arm 3`, `drop 3`. An accepted program's observable output
   changed with no diagnostic.

3. **q93b is newly rejected** (q93 without its unused `p`). Base prints `3`.
   HEAD says "a borrow of the temporary … outlives its statement", because the
   plain `?P` payload is now a view into the held value instead of a copy.
   The oracle reports `stricter prod=reject ref=accept`.

**Fix.** Hold only where a binding needs a place: the payload or element type
is not `copyable`, which is the same test `checkOptionalBinding` already uses.
A plain part stays the base behavior: read in the header, and the temporary
dropped at the header's end. Tests: t16, d01 (with its expected drop order)
and q93b as behavior tests.

## M1 (Medium): what a held payload is

There are three versions:

- **INTERNALS "Header subjects"** (row "a part of a made value"):
  `var _h = <e`, then the header over `<_h.f`; each payload is "the
  construct's own: a place in `_h` that a `?self` method may change and `<x`
  may move out".
- **Code and SPEC** (`sema.Header.held`: "the part is viewed in it";
  `walkMatch` sets `lent` for held; SPEC "its payloads are read where they
  are"): the header runs over `?_h.f`. `<r` is rejected ("cannot move out of
  `r`: it is borrowed from `mkh()`", h07, m05).
- **The oracle** sides with INTERNALS: m05 gives
  `stricter … prod=reject ref=accept`.

The Core does not imply the rule either. §3 lists what a header takes ("a
call's result, or a branching value whose every branch is made there") and
says "A header's temporaries end with the header". Holding a part's whole made
value through the body is a new rule. By AGENTS ("a rule the Core does not
imply is a bug"), either the Core gains a sentence for parts of made values,
or held is narrowed to the H3 fix and specified as INTERNALS states it. The
doc, the code and the oracle must then agree.

## M2 (Medium): a taken Cell-holder binding cannot be lent

**Repro** (`e01_taken_lend.rig`):
- `for k in two()` (a taken made array) with `touch(?k)` or `touch(k)`;
- `match mk()` (taken) with `.a(c) => touch(?c)` or `f = |?c| …`.

Each is rejected with "cannot borrow this: it holds a Cell, and `k` is a loop
or match binding, a copy, so changes through the borrow would be lost"
(`typecheck.zig:3543`, `lendsToRead`; and `:8358` for captures).

The binding is not a copy. It is the construct's own element, reached by
pointer (`for (&__rig_src_N) |*k|`), and `k.hit()` on it is accepted. The new
SPEC Cell text says a binding "owns one a loop or match takes". The same
rejection hides q03's real reason, which should be "`k` does not live long
enough".

This is not a regression (base rejected these programs), but it contradicts
the new docs. **Fix:** `lendsToRead` and the capture check should ask the
header fact (taken, so the binding is an owned place) instead of
`place.root == .pattern`, and drop the "a copy" reason.

## M3 (Medium, design): the payload split is an exception list

A read payload is bound in one of three ways:
- plain data: a copy (sound);
- unique: `?F` by pointer (sound);
- owner: an alias of type `F`, emitted as a bitwise copy.

INTERNALS states two cases: "a copy when it is plain data, a view in place
(`?E`) otherwise". The owner case is the exception, and it is the source of
C1. It is also visible in typing: `saved = r` is accepted for a unique payload
and rejected for an owner one, which needs `saved = ?r` (o01).

Since step 3 kept the owner case out, the brief's question "is that split
sound?" has the answer no (C1). "Is it an exception list the Core doesn't
support?" has the answer yes: Core sentence 1 says a bare place reads owners
in place, with no distinction from unique types. Closing C1 by viewing every
non-plain payload removes the split.

## L1 (Low): stale text

- `typecheck.zig:3543`, `:8358`: the "a loop or match binding, a copy" reason
  (see M2).
- `typecheck.zig:4667`, `:6667`: "iterate with `for x in ?v` instead". The
  bare form works now.
- `typecheck.zig:1893`: "resource Vec[T] iteration requires an explicit read
  borrow; write `for x in ?vec`". A bare place is viewed now, so this is likely
  dead or stale.
- The m14 message names `mk().arr` as "`mk.arr`".
- `checkMatch` has the comment "A place is matched where it stands, as
  `match ?p` would; a part of a made value where the match holds it." twice.

## L2 (Low): the kept corpus probe q93 masks H3

`test/corpus/review-step1-round2-q93_match_temp_plain.rig` binds `.a(p, q)`
with `p` unused. Its "`p` is bound but never read" error makes it a rejection
at both base and HEAD, so the corpus cannot see H3.3. Keep q93b (with `_`) as
a behavior test.

## L3 (Low): the held base is derived from syntax three times

`typecheck.madeBase`, `ownership.holdBase` and `heldPath`, and
`emit.emitHeld` each strip `member`/`index` nodes to find the held base. They
agree today: typecheck checks that the base is `.made`, and the other two
trust that `Header.held` was recorded. AGENTS says "one classifier per fact …
no pass re-derives one from syntax", so the `Header` fact should carry the
base node. The `classify` lint does not catch this, because it greps only the
old classifier names.

## L4 (Low): held rejections INTERNALS does not list

INTERNALS does not mention these conservative rejections:
- `if mk(1).o as r and c` and `if c and mk(2).o as r`: "bind this `Res?` to a
  name first" (h01);
- value-position `x = if mk(3).o as r` (m08);
- `while mk().o as r`, because `no_hold`.

All are sound. List them in "Header subjects", or lift them.

---

## 1. Header subjects: what holds

- **Viewed places, mutated while bound.** These are rejected, with the loan on
  the root, through views and write views (v01–v12, y01–y05, w01–w02):
  - `!v.push` inside `for _ in v`, even when the binding is unused;
  - `s = …` or `-v` inside the loop, `!t.add` inside `for b in t`;
  - `<p` or `o = none` while `x` is used;
  - `b = Box(…)` or `<e` or `e = …` inside an arm;
  - `!s.v.push` through `r = ?s; for x in r.v`;
  - `!w.v.push` in `go(w: !S)`.

  Once a binding is dead, writes are allowed and are correct (`if o as x:
  print(x.len); o = none` runs clean, v08).
- **Guards** may not change the subject (g01–g03).
- **`while … as` re-evaluation.** A move in the body is reported as "use of
  `o` after move … in a previous iteration". Reassignment after the binding's
  last use runs correctly (v09, w03).
- **Held lifetimes** (non-plain, no temporaries in the base; m01, m02, m06,
  n01, n02, hb01–hb05) are correct and sanitizer-clean:
  - `return`, `break`, `continue`, `break :outer`, `continue :outer`;
  - `for … else` value loops;
  - guards, nested held matches, and `defer` in arms and loop bodies;
  - bases written with `!` and `?`, and branching bases with a `<a` leaf on
    both paths.

  Each drops the held value exactly once, at the construct's exit. Escapes are
  reported: `saved = r`, `?r` as a value, `break k`, `return k`.
- **Branching subjects of a moving type** are rejected (q50–q59). Plain-data
  branches copy.

## 2. Implicit argument lends: what holds

- The owner stays lent for the call, and for as long as a kept view is used:
  - `keep(b); -b`, `keep_s(v); !v.push`, `keep_t(t); !t.add`;
  - Box and handle forms;
  - a later argument that writes or moves the same root (`total(v,
    grow(!v))`, `get(h, eat(<h))`, `twice(cb, eat(<cb))`);
  - keyword arguments in either order (b01, k01–k05, l05–l10).
- A bare Copy argument keeps its loan: `add(!n, n)` and `setp(!p, p)` are
  rejected. `seti(!n, n)` with a by-value `Int` is rejected as at base.
- Statement temporaries of made values are correct everywhere except hoisted
  calls (H2). A view kept past the statement is rejected (t03–t07).
- Generic inference: `first(v)` with `xs: []T` and `keep(t)` with `?T` work
  (b03). `math.min(a, b)` with two Texts is rejected (`T = Text` has no `<`),
  so risk (4), inferring `T = String`, is not built. That is still a
  rejection, so it is sound.

## 3. The lend table: what holds

| Row | Emitted as | Loan |
|---|---|---|
| `X?` | `if (o) \|*p\| … else null`. A temporary goes through `rig.keep(...).*`, an lvalue, so the view is never a copy of an owning optional. Plain, owner, Cell-holder, Box and handle optionals all work (l03, l11, z01). | on `o` (l01, l02) |
| `*T` | | on the handle's binding: `-h`, `h = …`, `<h` conflict, and so does `-g` for `first(g)` of a cloned handle (l05–l07, x05, x06); through a field, on the field's root (l13) |
| `Box[Text]` → String | | on the box's root through one and two boxes (l08, l09, x03, x04) |

Composition (`Box[Box[Box[Text]]]`, `*Box[S]`, `Box[S]?`, `(*S)?`, `(*Text)?`,
`*Box[[3]Int]`, `Box[Vec[Int]]?`, `Box[Box[Vec[Int]]]`) runs correctly (z01).

## 4. Cell ⇒ unique: what holds

These copies are rejected:
- binding, field, element, array, `??`, ternary branches;
- `+x`, `[n of x]`, `fill`, `Cell.get`, `arr.get`;
- struct field initialisation, enum payload construction, element assignment;
- a `Wrap[Counter]` or `Opt[Counter]` instance;
- a generic `[n of x]`;
- `|+a|`;
- an optional argument (c01–c21).

Generic read-match payloads still require `no_cell`, which is conservative
(c21). A by-value parameter owns its Cell, including in closures and with
`<self` (p01).

## 5. Emit and checker

`Header` and `lendOf` are read by typecheck, ownership and emit. The exceptions
are C1, where a payload's representation is decided by its type in emit but
modelled as an alias in ownership, and L3. The `classify` lint passes.

## 6. Step-1 review probes at HEAD

There is no crash, no Zig compile error and no leak. q09, q14, q16 and q17 run
and change the Cell in place. q90, q91 and q92 are rejected (the view outlives
the temporary). q50–q59 are rejected. q06 and q71 run. q03 is rejected for the
stale reason (M2). q93 is rejected; see L2 and H3.

## 7. Docs

- **CORE §1 bullet** *(built)*: true.
- **CORE §4 rows** marked built: true as lends.
- **CORE sentence 1** "*(built* … a header's subject (… a `match` on a
  `Box`)": not true for owner payloads (C1).
- **INTERNALS "Header subjects"** does not match the code in two places:
  - owner payloads are aliases in the code, not `?E` (M3);
  - held payloads are viewed in the code, not owned (M1).

  It also omits the L4 rejections.
- **SPEC "Cell"** says a taken binding owns its value. That is true for `?self`
  methods, but lending it is rejected (M2).
