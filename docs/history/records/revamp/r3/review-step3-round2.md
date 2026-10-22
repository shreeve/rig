# Review round 2: REVAMP-3 step 3 fixes (`r3-step3` HEAD `58250e50`)

Reviewer: the round-1 reviewer (`review-step3.md`). I built HEAD from
`git archive` in a scratch copy (`zig build`, `zig build oracle`).

Probes:
- all 160 round-1 probes (`probes/review-step3/*.rig`) were rerun at HEAD;
- 30 new probes are in `probes/review-step3/r2/`;
- the round-2 step-1 probes were rerun for the M2 and L2 checks;
- the oracle (`-v`) was run over every probe.

Older builds compared: the round-1 build (`5e38370e`) and the step base
(`911d91c0`). I ran no suites and modified no tracked files. A pause request
from the lead arrived after the probing was done; nothing was run after it.

## Verdict

Every round-1 instance is fixed. H1, H2, H3, M1, M2, L1, L3 and L4 are fixed
as classes. **C1 is not fixed as a class.**

The new rule binds every non-plain read payload by pointer (`|*p|`,
`&subj.v.f`). That rule is right, but it is only sound when the pointer points
into the matched place. Three emit paths still match a **copy** of the subject,
while the checker records the bindings as views of the original:

- **R2-C1 (new).** A guarded match on a subject with no storage copies it into
  `var __rig_subject_N`. Such subjects are a call returning a view, or a
  subject with header temporaries.
  - The payload views of the copy escape and dangle (g10, g14, g15).
  - A Cell change lands in the copy (g19).
  - The boxed form does not compile (g21c).
- **R2-C2 (pre-existing, C1's class).** A payload of a type parameter is still
  a copy. Only `no_cell` is required of each instance, so `T = Res` lets
  `?v` escape and dangle (g12).
- **R2-C3 (new form).** In a generic body, a catch-all `x => x` is captured
  by pointer from `rig.borrowed(...)`, which is an rvalue copy. The result
  dangles (g13). In round 1 this form was a Zig compile error.

Round 1's C1 was a soundness finding in this feature, and these are new
soundness findings in the same feature: binding read payloads as views. By
AGENTS ("a second soundness round stops the feature"), payload views in
matches stop for a redesign.

There is one more High finding, R2-H1. It predates step 3, but it contradicts
CORE §1's *(built)* status for "a type that holds a `Cell` is unique".
`if … as` over a lent optional whose header makes a temporary copies the inner
value, so a Cell change through the binding is silently lost (g20).

The oracle accepts every one of these (`prod=accept ref=accept`): it models
the payload as a view and does not see emit's copy.

| # | Sev | New? | Finding |
|---|---|---|---|
| R2-C1 | **Critical** | yes: the dangling form is new in a596a515; the Cell fork dates from 5e38370e | A guarded match on a subject with no storage matches a copy. Its payload views escape and dangle, change a Cell in the copy, or fail in Zig. |
| R2-C2 | **Critical** | no: base, round 1 and HEAD all have it | A read payload of a type parameter is a copy. `?v` of an owner instance escapes the arm and dangles. |
| R2-C3 | **Critical** | new as a runtime bug (round 1 failed in Zig) | A generic catch-all `x => x` is captured by pointer into the `rig.borrowed` rvalue and dangles. |
| R2-H1 | **High** | no: base has it | `if f(…, temp) as c` over a lent optional of a Cell holder binds a copy, so `c.hit()` is lost. CORE §1's *(built)* is false here. |
| R2-M1 | Medium | new forms | Nested payload views and payload views inside a loop body are falsely rejected: the loan is rooted at the inner binding (n10, n11; the oracle says `stricter`). |
| R2-L1 | Low | | `match b` on a `Box[Int]` with literal patterns still reports "expected `?Int`" (t17). This is a rejection either way. |
| R2-L2 | Low | | The corpus q93 still carries its unused `p`, which masks what the probe was written to test. Its corrected form q93b runs (`3`). |

---

## R2-C1 (Critical): a guarded match on a subject with no storage matches a copy

**Where.** `emit.evalSubject` runs for every guarded match. For a subject
without storage (a call returning `?E`), and for one with header temporaries,
it writes:

```zig
var __rig_subject_2: E = (get(e)).*; _ = &__rig_subject_2;
...
0 => { const r = &__rig_subject_2.a.r; break :__rig_blk_4 r; }
```

The ownership checker gives `r: ?Res` the subject value's loans, which are on
`e`. So `r` may outlive the match, but it points into the block-local copy.

**Repro** (`r2/g10_guard_lend_subject_escape.rig`):

```rig
struct Res
  n: Int
  t: Text

enum E
  a(r: Res)
  b(r: Res)

fun get(e: ?E) -> ?E
  e

fun inner(e: ?E) -> ?Res
  match get(e)
    .a(r) if r.n > 0 => ?r
    .a(r) => ?r
    .b(r) => ?r

fun clobber(n: Int) -> Int
  a = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]
  b = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]
  a[1] + b[2]

sub main
  e = E.a(r: Res(n: 1, t: Text("hello")))
  x = inner(e)
  print(clobber(1000))
  print(x.n, x.t)
```

HEAD prints `2003` and then `1 ` with the Text gone. The round-1 build and the
base reject it ("`r` does not live long enough").

**Siblings:**
- `g15`: a guarded catch-all `x => x` on `match get(e)` prints
  `.a(r: Res(n: 4345818832, t: "�"))`. Round 1 and the base fail in Zig.
- `g14`'s `inner3`: `match get2(e, Text("xyz").len)` with a guard. It crashes
  with `FAULT` in `print`. The unguarded `inner2` works, because it switches on
  `get2(...).*` in place.
- `g19`: the same shape with a Cell holder. `.a(c) if … => c.hit()` changes the
  copy: `e` still prints `hits: 1` where the meaning is `2`. This is a silent
  Cell fork, present since 5e38370e (the base rejected it).
- `g21c`: the boxed form (`match getb(b, Text("xyz").len)` with a guard)
  declares `var __rig_subject: Box(E) = ….value.*`. It is accepted, and Zig
  fails with "expected type 'Box(E)', found 'E'".

**Class.** This is "the checker checks exactly what is emitted": emit adds a
copy of the subject that the checker never walks. Every emit path that
evaluates a subject into a `var` and then captures by pointer is affected.
That includes `evalSubject`'s `var` branch, and `info.boxed and hasTemps` with
`.value.*`.

**Fix direction** (a redesign, per AGENTS):
- a subject whose bindings are views is never copied;
- a lend subject is held as the pointer it is: `const s = get(e);`, then
  re-read as `s.*`;
- a subject with header temporaries is held in the header's slots, with
  `rig.keep(...)` as an lvalue, and pointed into.

If a copy is unavoidable, it must be a hidden var that the checker walks, so
that the loans root at the copy. Then g10 is rejected as "does not live long
enough".

Tests: g10, g15, g19 and g21c, plus a matrix axis: subject {place, lend call,
lend with temporaries, boxed lend, held} × {guarded, unguarded} × payload
{owner, Cell holder} × {escape, Cell change}.

## R2-C2 (Critical): a type parameter's read payload is a copy whose view escapes

**Where.** `checkVariantPattern` makes a payload a view only when `copyable ==
.no`. A payload of type `T` is `.depends`, so it stays a copy, and only
`no_cell` is required of each instance. INTERNALS now says "(A payload of a
type parameter is a copy, which each instance must allow.)", but an owner
instance is allowed.

**Repro** (`r2/g12_generic_payload_escape.rig`):

```rig
struct Res
  n: Int
  t: Text

enum Opt[T]
  some(v: T)
  nothing

fun peek[T](o: ?Opt[T], d: ?T) -> ?T
  match o
    .some(v) => ?v
    .nothing => d

fun clobber(n: Int) -> Int
  a = [n, n + 1, n + 2, n + 3, n + 4, n + 5, n + 6, n + 7]
  a[1]

sub main
  o: Opt[Res] = .some(v: Res(n: 7, t: Text("seven")))
  d = Res(n: 0, t: Text("d"))
  x = peek(o, d)
  print(clobber(1000))
  print(x.n, x.t)
```

The emitted code is `const v = __rig_payload_1.v; break … rig.lend(&v);`. The
program prints `1001`, then `0 ` followed by garbage, then panics in `print`
("syscall error: INVAL"). `g12b` (`peek(?o, ?d)`) does the same on the base and
the round-1 build.

The other generic copy bindings are protected:
- a generic loop element is rejected ("views in a slice a value that holds a
  `T`");
- a generic `as` is rejected (gen01, gen02);
- generic held parts are rejected as temporaries (gen04, gen05).

Only match payloads are missing their instance requirement.

**Fix.** Either bind a `T` payload by pointer as `rig.ReadBorrow(T)`, as the
non-generic rule does, or require of each instance what a copy needs: `T` must
be `copyable`, which rules out owners and unique types. A `?v` of a copied
payload must then root its loan at `v`.

## R2-C3 (Critical): a generic catch-all binding points into an rvalue copy

**Repro** (`r2/g13_generic_whole_escape.rig`):

```rig
struct Res
  n: Int
  t: Text

enum Opt[T]
  some(v: T)
  nothing

fun whole[T](o: ?Opt[T]) -> ?Opt[T]
  match o
    .nothing => o
    x => ?x

sub main
  o: Opt[Res] = .some(v: Res(n: 7, t: Text("seven")))
  x = whole(o)
  print(x)
```

The emitted code is `switch (rig.borrowed(Opt(T), o)) { … else => |*x| x }`.
`rig.borrowed` returns `borrow.*` by value, so `x` points into the switch's
temporary operand. The program prints `.some(v: Res(n: -69242844270821376, t:
"…` and panics. In round 1 this was a Zig compile error; the catch-all fix
(`wholeExpr`, `|*x|`) made it compile and dangle.

This belongs to R2-C1's class: the pointer captures a copy the checker never
sees. The generic `ReadBorrow` path must switch on `o.*`, or on a held pointer,
whenever a binding views the subject.

## R2-H1 (High): `if … as` over a lent optional with header temporaries forks a Cell

**Repro** (`r2/g20_ifas_temp_cell.rig`):

```rig
struct Counter
  hits: Cell[Int]

  sub hit(?self)
    self.hits.set(self.hits.get() + 1)

struct H
  o: Counter?

fun geto(h: ?H, n: Int) -> ?Counter?
  ?h.o

sub main
  h = H(o: Counter(hits: Cell(1)))
  if geto(h, Text("xyz").len) as c
    c.hit()
  print(h)
```

It prints `H(o: Counter(hits: Cell(value: 1)))`, but the meaning is `2`.

`emitOptionalHead`'s path "a borrow of a temporary the header drops: … the
binding views a copy of the value inside" stops the copy from escaping, but
not from being changed through a Cell. Since Cell ⇒ unique, a Cell holder must
never be copied. Base (`g20b`, with `?h`) and round 1 behave the same, so this
predates step 3. Step 3 now marks Cell ⇒ unique as *(built)*, and this is a
counterexample.

**Fix.** Hold the header's temporary in its slot and point into it, as for
R2-C1. Alternatively, reject a Cell-holding binding there ("bind it to a name
first").

## R2-M1 (Medium): payload views of views are rooted too narrowly

Two forms are rejected that should run:
- a nested match whose payload view comes from an outer payload view (`n10`:
  "`i` does not live long enough");
- a match inside `for e in v` that stores a payload view outside the loop
  (`n11`: "`e` does not live long enough").

In the original form of `n11`, `return r` was rejected with "cannot move out of
`r`: it is borrowed from `e`", even though `r: ?Res` is a view and a view is
returned by copy.

These are sound but false rejections; the oracle reports `stricter … prod=reject
ref=accept`. Under Core sentence 1 the inner binding is a view of the outer
place, so its loan should root at that place.

## Round-1 findings: status at HEAD

| Round 1 | Status | Evidence |
|---|---|---|
| C1 owner payload stack copy | **fixed for non-generic subjects with storage; open as a class** (R2-C1, R2-C2, R2-C3) | o02, o04, o10, o11, o12, o16: correct values. o15 and o15b run. |
| H1 held base with temporaries | **fixed** | t01, t02, t08, t09, t10 are rejected with "this header holds … bind … to a name first". The boundary covers implicit lends, `?mk()`, Cell temporaries, and an array temporary held in a struct (h20, `mkv([n, n])`). A closure literal and a slice temporary in the base run correctly (h20). The oracle no longer fires. |
| H2 hoisted implicit lend | **fixed** | a03 to a03d, a06, a07, a10, a11 run with the right drops. |
| H3 held over plain data | **fixed** | t11, t12, t14, t15, t16 run as on the base. d01 restores `drop 3` before `arm 3`. q93b prints `3`. Generic parts are rejected conservatively (gen04, gen05). |
| M1 held semantics | **fixed** | INTERNALS, SPEC and `sema.Header` now agree: viewed (`?_h.f`). h07 and m05 are rejected (move out of a view, or the view outlives the temporary). |
| M2 taken Cell holders lent | **fixed** | e01 runs (`touch(?k)`, `touch(k)`, `\|?c\|`). q03 now says "`k` does not live long enough". |
| M3 payload split | **fixed for concrete types; the generic `T` exception remains** (R2-C2) | o01: owner payloads are `?Res`. |
| L1 stale text | fixed | |
| L2 q93 masked | **open** | The corpus q93 is unchanged (R2-L2). |
| L3 held base from syntax | fixed | The base is recorded in `HeaderFact.base` and read through `heldBaseOf`. |
| L4 undocumented held rejections | fixed | INTERNALS lists them. |

Everything else from round 1 still holds at HEAD:
- every lend-table row and its loans;
- the Cell ⇒ unique copy paths;
- viewed places mutated, moved or dropped;
- guards that change the subject;
- `while … as`;
- held lifetimes with jumps, `defer` and nested headers (n01, n02, hb01 to
  hb05, m01, m06).

## The lead's accepted behaviour changes

- **The unused-binding lint covers owner payloads** (o01). Sound.
- **A Cell holder is printed as it is when the call runs.**
  `print(c, bump(?c), c.hits.get())` prints `Counter(hits: Cell(value: 2)) 0 2`
  (k10). Sound: the holder is read by address, and its Cell changes in place.
  A conflicting write is still rejected by #42's holds, for example
  `print(r, reset(!e))` while a payload view is live.
- **`print(a if f else b, bump(?a))` with Cell holders is rejected.** This is
  conservative and sound.

I found no interaction between #42's holds and the header views beyond what
the holds already reject.
