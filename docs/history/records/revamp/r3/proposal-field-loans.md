# Proposal: field-disjoint loans

Status: design only. Probes ran `bin/rig check` on main's binary, built
before #150 and #152, whose only ownership change is a `match` speed
fix. The oracle binary (Oct 10) parses no 0.3 program: no oracle
verdict is claimed.

## 1. The problem

Trig item 1 (NEEDS 28), reduced:

```rig
obj Arena
  names: List[String]

  sub mk(!self, t: ?String)
    !self.names.push(String(t))

obj Parser
  a: Arena
  t: String

  sub step(!self)
    (!self.a).mk(self.t)          # rejected

sub main()
  p = Parser(a: Arena(names: List()), t: String("id"))
  !p.step()
  (!p.a).mk(p.t)                  # rejected
  print(p.a.names.len)
```

Both: "cannot lend `self` (`p`) to write while a read loan is live".
`mk2(!self.a, self.t)`, a free `sub mk2(a: !Arena, t: ?String)`: "cannot
lend `self` to read while a write loan is live". Trig's lexer
(docs/lexer/repros/field-loans.rig), a slice of one owned field:

```rig
obj Scanner
  text: String
  flags: Int

  sub tag(!self)
    t = ?self.text[0..2]
    self.flags |= 1               # cannot assign to `self.flags` while `self` is lent
    print(t)
```

Today every one of these is a loan on the whole root var. The cost in
Trig: one `+self.scanner.token_value` String allocation per identifier
and literal in the parser, and a scanner that cannot own its text.

## 2. Today's rule, exactly

A loan names a var and nothing below it.

- `Loan` (src/ownership.zig:154-183) has `root: VarId` and no path.
  `Place` (:2185-2195) has `root` and flags; `resolvePlace` (:2200)
  drops the field names.
- Every conflict check asks about the root: `conflicts(id, access, pos)`
  (:859) through `findLoan(root, q, skip)` (:1419) and `loanMatches`
  (:5922, `l.root == root`). Its callers: `lendVar` (:2479, for `walkLend`
  :2431, `walkElems` :2496, captures :4575), `checkReadable` (:2132),
  `walkTake` (:2738), `moveVar` (:2816), `walkDrop` (:3070),
  `checkAssignable`/`reassign` (:3549, :3570), `walkFieldAssign` (:3647,
  "cannot assign to `p.n` while `p` is lent"), the write receiver's
  activation (:3926, :4001), and `walkFor` (:5277).
- Temporaries a call adds are whole-root too: the receiver's
  `place_hold` and its two-phase reservation (:3871), `holdRead` (:4056),
  `walkIndicesHeld` (:2247).
- The one exception is `swap`: `walkSwapCall` (:4223) hides the first
  place's temporaries while the second is walked when `disjointFields`
  (:4272) says the two paths differ. `disjointFields` compares the
  source text of two `fieldChain`s (:5902): a second, syntactic
  classifier of places, used by one builtin.
- What a var *holds* is also per var: `Flow.loans` (:188). A field that
  holds a view and is re-pointed keeps the old view's loans in the
  var's flow (`walkFieldAssign` :3675 unions). That is n39,
  "field-precise re-pointing" (HANDOFF.md:160).

The oracle already records paths (`core.Loan.path`, `core.Access.path`,
test/oracle/core.zig:88-136, built by `Lowerer.place`, lower.zig:1927),
`Step = field | elem`, and uses them only for `swap`: `flow.zig`
`conflicts` (:310-319) skips a loan of the same `group` on a `disjoint`
path (:321, `elem` overlaps).

## 3. The Core change (owner approval needed)

Replace sentence 5's heading and first line:

> **5. A place has any number of read loans, or one write loan, never
> both.** A loan on a place covers every place inside it, so two
> places conflict when one holds the other: `p` and `p.a`, `p.a` and
> `p.a.b`, but not `p.a` and `p.b`. This holds for every type, numbers
> included. *(built;* for fields, *planned.)*

Add to §5, after the list of what a place is:

> **A field is a place of its own.** A path is a name and the fields
> after it, through what a write view the name holds sees, and through
> a box. It stops at an element, a handle, or an optional's value, and
> the loan is on the path so far: `?v[i]` and `!v[j]` are both loans on
> `v`, and `?h.f` with `h: *T` is a loan on `h`. A use touches the path
> it names: `?p.a`, `!p.a`, `<p.a`, `p.a = x`, `(!p.a).m()`, and
> `swap(!p.a, !p.b)` touch `p.a` (and `p.b`); `p`, `<p`, `p = x`,
> `(!p).m()`, and `!p.m()` touch all of `p`. A value never holds a view
> of itself: storing in a part of `p` a value that carries a loan on a
> part of `p` is rejected. *(planned)*

The last sentence is today's behavior, which whole-root loans give for
free (`a.x = ?a.y`: "cannot assign to `a.x` while `a` is lent"). With
paths it must be said. Without it, `(!p.a).keep(?p.b)`, where `keep`
stores its argument in `self`, puts a loan on `p` into `p`, which
`absorbLoans` drops (:4402); then `p.b = String("z")` frees the bytes
`p.a` views, and no loan stops it. Rust instead allows a self-view and
then forbids moving the value; Rig has no rule for a var holding a loan
on itself, and does not need one.

## 4. Desugaring

A struct binding `p` with fields `a` and `b` is, for loans, the group of
bindings `p.a` and `p.b`, recursively, that move, drop, and are lent
together by a use of `p`. `(!self.a).mk(self.t)` is

```text
w = !self.a ; t = ?self.t ; w.mk(t)
```

with `self.a` and `self.t` two bindings, which sentence 5 allows. A
box has one owner (sentence 8), so its value's fields are the owner's.
An element is no binding (its index runs, and a push moves the buffer),
nor is a handle's shared contents, nor an optional's value, which
exists only while present. Emit is unchanged (it passes `&self.a` and
`self.t`'s bytes; Zig has no aliasing rule), and no temporary or order
is added; the grid confirms each newly accepted form runs clean.

## 5. The fact and its one classifier

- **The path of a place** is decided once, by `resolvePlace`, which
  returns it. Positive list of the steps that extend a path: a field of
  a struct value, of a box's value, or of what the root's own write view
  sees. Any other step (an index or slice, a handle, a read view, an
  optional's value) ends it, and the loan is on the path so far.
- **`Loan` gains `path: PathId`** (a u32 into a per-function interner;
  empty is the whole var); `sameAs` compares it. `conflicts` takes the
  access's path; a move, drop, reassignment, or whole receiver passes
  the empty one.
- **Overlap** is one function, `pathsOverlap`: one path is a prefix of
  the other. Only `loanMatches` calls it.
- **`swap`** loses its special case: `disjointFields` and the
  temporary-hiding in `walkSwapCall` (:4229-4238) go. `sameCollection`
  stays as the hint for `swap(!v[i], !v[j])`.
- **Self-views**: `walkFieldAssign` (:3631) and `absorbLoans` (:4393)
  reject a stored loan on the target's own root. `absorbLoans`'s filter
  (:4402) keeps skipping only the call's own lend of its receiver.
- **Unchanged:** `Flow.loans`, `carry` (judged by the var's type),
  liveness, exits, `isLent` counts, external loans.

## 6. The oracle

`flow.zig` `conflicts` (:310) drops the `group` condition, so `disjoint`
applies to every loan, and `group` goes. `lower.zig` `place` cuts the
path at a step through a handle (`handle_at`) and into an optional's
value, as the compiler does (elements already overlap); every whole-var
access keeps an empty path. A new check beside C4 makes a store into a
part of root `r` of a value carrying a loan on `r` a finding.
`test/oracle/rejections` gains the new reject tests' functions.

## 7. Each form, decided

| Form | Rule | Why |
|---|---|---|
| `p` vs `p.a`, `p.a` vs `p.a.b` | overlap | prefix |
| `p.a.b` vs `p.a.c` | disjoint | |
| `self: !T`, `?self.a` vs `self.b = 1` | disjoint | the path continues into what the root's write view sees |
| local `w = !p.a`, then `?p.b` | disjoint | the loan `w` holds is on `p.a` |
| through a field that is a `?T` or `?String` | no loan on the var, as today | `walkThroughView` |
| `^T` box `b`: `?b.a` vs `b.n = 1` | disjoint | one owner; the box never moves while lent |
| `*T` handle `h`: `?h.a` | loan on `h` (or on `p.h`) | contents are shared; only a Cell changes them, by a marked call |
| optional field `o`: `if ?p.o as s` vs `p.n = 1` | disjoint | |
| `if ?p.o as s` vs `p.o = none` | overlap | same path |
| `v[i]` vs `v[j]`, `p.items[0]` vs `p.items[1]` | overlap | stays; `!v.swap(i, j)` is the form |
| `p.items[0]` vs `p.n` | disjoint | the path stops at `items` |
| `(!p).m()`, `!p.m()`, `(?p).m()` | the whole of `p` | the signature lends all of `self`; see §8 |
| `<p.f` while `?p.g` | allowed | take writes `p.f` only |
| `<p` while `?p.g` | rejected | whole |
| `p.f = x` while `?p.g` | allowed | |
| `p.f = ?p.g` | rejected | self-view |
| `swap(!p.a, !p.b)` | allowed by the rule | no special case |
| a `swap` of `p.a` and a place inside it | rejected | prefix (the two types also differ unless the type nests itself) |
| `r = head(?p.a)`, then `p.n = 2` | allowed | `r` carries the loan on `p.a` |
| `r = (?p).first()`, then `p.n = 2` | rejected | a method's result carries its receiver: all of `p` |
| field holding a read view: `p.v = ?q`, then `?p.v[0]` | carries `p`'s held loans | unchanged; per var |

## 8. What stays conservative, and why

- **Elements**: an index is a run-time value; Rust overlaps them too.
- **Handles**: every handle reaches a `*T`'s contents.
- **A method on the whole receiver**: `!self` lends all of it, and so
  does the view a `!self` method returns. Narrowing that needs a path in
  the signature (`from self.text`), the separate "path tokens" item
  (rig-questions E.4); see the call-stores proposal, Appendix A.
- **What a var holds** stays per var (n39): re-pointing `p.v` does not
  end the old view's loans while `p` lives. That is another fact, and
  Trig reports no line that needs it.
- **`carry`** judges reach by the var's type, not the path's: another
  classifier, not this round.
- **A path past the interner's bound** (say 8 steps) is cut there: a
  shorter path only adds conflicts.

## 9. Sibling sites and test plan

Sites: every `conflicts` and `findLoan` caller of §2; the temporaries
`place_hold`, reservation, `holdRead`, `walkIndicesHeld`;
`walkSwapCall`; `walkFieldAssign` and `absorbLoans` (self-view); payload
bindings (`alias_of`, `alias_path`, :237-238) and `skip_alias_of`;
`match !p.a`; `for x in !p.items`.

Reject tests (`test/reject/ownership/field_*`): `p.a = ?p.b`;
`(!p.a).keep(?p.b)`; `link(!p.a, ?p.b)` storing into its first
argument; `?p.a` then `<p`, `p = P(...)`, or `!p.m()`; `?p.a.x` then
`p.a = ...`; `?p.items[0]` then `!p.items.push(1)`; `?p.h.a` then `!p.h`
reassigned; `if ?p.o as s` then `p.o = none`; `r = (?p).first()` then
`p.n = 2`.

Run tests (`test/behavior/ownership/field_*`, each printing what it
saw, sanitizer-clean): the Trig forms of §1; `print(p.a, grow(!p.b))`;
`!p.items[i] = f(!p.n)`; a box's two fields; `<p.f` while `?p.g` lives;
a write view local of one field beside a lend of another; `match !p.a`
arms writing `p.b`; a struct with a `drop` body lent field by field.

Matrix: a `field.` grid: first form {`?p.a`, `!p.a`, `?p.a[..]`, an
implicit `p.a` argument, `(!p.a).m()`, `match ?p.a`, `if ?p.o as`, `for
x in ?p.items`, `w = !p.a`, `r = head(?p.a)`} x second form {read,
assign, lend, take, method, `swap` of `p.b`; the same of `p.a.x`; `<p`,
`p = ...`, `!p.m()`} x root {local, `!T` parameter, `^T` local, nested
field, `*T` field, element}; verdicts from §7, run in debug and
`--release`.

Corpus: Trig's field-loans.rig, the program of §1, and the self-view
probes above.

## 10. Size and order

One round: `src/ownership.zig` (Loan, Place, the overlap function,
about twenty sites, the self-view check, the swap deletion), the oracle
(three sites and a check), CORE, SPEC ("Second-class views", "Replace
and swap"), INTERNALS (Ownership), and the tests. It changes a soundness
classifier, so it runs the full matrix and oracle gate.

Open PRs: #159 (b123) changes `src/ownership.zig` and typecheck; #151
(trigfix) changes typecheck's classification and the oracle's
`lower.zig`; #156 (simd2) touches both lightly. None touches a loan
site, but under "one branch at a time" this round starts after #159 and
#151 land, and passes the full gates with #156 if it lands first.

## 11. Questions for the owner

1. Approve the sentence 5 and §5 text of §3? Recommend yes.
2. Boxes transparent (`b.a` and `b.n` disjoint for `b: ^T`)? Recommend
   yes: one owner, as CORE §1 says a box behaves.
3. State "a value never holds a view of itself" in CORE, rather than
   allowing it and forbidding the move afterward, as Rust does?
   Recommend yes: it is today's behavior and the simpler rule.
4. Field-precise re-pointing (n39) in a later round of its own, though
   HANDOFF says "with"? Recommend yes: a different fact, no Trig need.
5. Accept that a `!self` method's view result still lends all of
   `self`, leaving `from self.text` to the path-tokens item? Recommend
   yes for this round.
