# Review: seam2b fix commits (1f5e16c6, dff5d589, e4e327da, e416deb8)

Branch `seam2b` at e416deb8, built in /Users/shreeve/Data/Code/rig-seam2b
(`zig build`, `zig build oracle`). Scope: `git diff 7e58af0c..e416deb8`.
Probes are in `.git/revamp/r3/probes/review-seam2b-fixes/` (see its
`README`). Every run used `RIG_SANITIZE=1 bin/rig run`.

## Verdict

**No soundness hole found.** No accepted program used freed memory,
leaked, lost a write, or emitted Zig that does not compile.

- Medium 1 from round 1 is fixed. Every round-1 probe now compiles and
  prints the right state: zh01, zh02, zh05, zh09, zh10, iso/zh11_4,
  zh11_6, zh11_15, zh11_16, zh11_18, zh11_19 and zi02.
- Low 1 is fixed: y01 now runs clean, the same as its named form y02.
- Low 2 is fixed: one diagnostic per line.
- Low 3 is fixed: k03 now gives the bind-first advice.

The findings below are all Low.

## 1. `writesTemp`: one classifier, read at the one copy site

The fact is recorded in one place: `typecheck.lendsToWrite`, on
`placeOf(operand).base`. That is the only path that accepts a temporary
lent to write, and it serves both `synthLend` and write slices.

The fact is read in one place: `emitMemberBase`, where it skips the
`@as(T, …)` copy of a branching value. The old `write_place` flag had
only that one reader, and it is gone completely.

I checked the other places where emit copies a value:

- `emitIndexBase` goes through `emitMemberBase` for leaves.
- `emitSlice` uses `emitAddressOf` and `emitPlace`.
- `emitLeafPtr` reaches `dropsTemp` nodes through `&(keep…)`.
- The numeric `@as` in the `.if` arm only touches plain-number temporaries, where no write can be seen.

None of these copies a written temporary.

What the fuzzers checked:

- **`fuzz/gen.py`, 663 programs.** 13 heads were run through 51 write
  ops, each compared against the same op on `tt = HEAD`.
  - Heads: a call, `if` both ways, `??` and `catch` (taken and not),
    nested `if`, `??` inside `if`, a part of a branch, an element of an
    array literal, and an element of a branching array.
  - Ops: swap, replace, write slices and sort, hoisted receivers of
    the whole value and of a field, `=`, `+=` and `*=` on fields,
    elements and Vec elements, Text fields, generic `setg`,
    `.me().bump()`, `defer`, closures, `for`, `match` and `if`/`while as`.
  - Result: 503 OK, no ZIGERR, no CRASH (`run1.log`). The 11 DIFFs are
    all the `twice` op, which makes two temporaries; that difference is
    expected.
  - The 149 rejections are all expected: header copies, `for !` on a
    temporary, `setg[Text]`, a closure capture missing in my generator,
    and `brmix`, which is Low 2.
- **`fuzz/gen2.py`, 1792 programs.** 16 contexts × 8 heads × 14
  expressions. `check2.py` checks the state of each temporary in its
  drop line (for example `n==7` after `replace`, `kk==32` after a
  hoisted `put2v`, a sorted `arr`).
  - Contexts: `if` and `else if` conditions, `while` with `and`,
    `and`/`or` short circuits, ternaries, `match` arms, `defer`, `for`
    bodies, an assignment index, `+=`, nested calls, two in one call,
    and kwargs.
  - Result: 1776 OK with the write seen in the slot, no LOST, ZIGERR or
    CRASH (`check2.log`).
  - The 16 rejections are all `x if c else !H.me().bump()`, the
    pre-existing round-1 Low 4.
- **Hand probes `emit/e01`–`e19`**, all correct and sanitizer-clean:
  - swap of two branching temporaries;
  - heads of the form `(mkf(n)!)` and `(mkopt(n)?)` with
    swap/replace/sort/hoist;
  - generic bodies (`e04`, and `e19` with `GW[T]` branches);
  - whole-value swap and replace of a branch;
  - kwargs reordering with a branching write argument;
  - hoisted receivers of a whole `if`, `??` or `catch`;
  - doubly parenthesized heads;
  - elements of a branching array and Vec;
  - Text fields;
  - closures, `defer`, `while` loops;
  - `*T` and `Box` branches;
  - write slices of a whole branching array or Vec (`e18`).

The checker walks what is emitted: neither side changed what is made or
dropped, and the slot is now reached from every site.

## 2. `holdsPastDrop`: found sound

Checked a temporary holder with no drop body, made before the
temporary whose view it holds (`hold/hp01`–`hp34`). Results:

**Rejected correctly:**

- **Holders with a drop body somewhere inside:** the body's type is a
  Vec[H], H?, [1]H, Box[H], `Hold[H]`, or `Hold[EH]` with an enum
  payload (hp07–hp11, hp16, hp17).
- **Writes into a named holder through a view-typed temporary:**
  `pick(!h)`, `idw(!h)`, `!P(h: !h).put`, `!P(h: !h).hh()`, a branch of
  write lends, and `!h.me()` (hp01–hp06). The store lands on `h`, which
  is reported.
- **A view carried out by the holder:** `s = !mkpr().set2(...)` (hp13),
  `p = !mkpr().with(...)` (hp14), and an `if … as` binding (hp25). Each
  is reported through the binding.
- **A no-body holder viewed by a temporary that has a body:**
  `!W(p: !mkpr()).put(...)` (hp22) and `!mkw(!pr).put(...)` (hp24). The
  recursion finds W.
- **A generic body** (hp19, hp20). `.depends` is treated as holding, so
  this is conservative.

**Accepted and run clean:** `!mkpr().set(?mk(1).t)` (hp15),
`!Hold(v: "x").set(...)` (hp12), `!PW(w: !k).set(!mk(1).n)` (hp30) and
`replace(!PW(w: !k).w, ...)` (hp31). The last two write through the
view, and the named form behaves the same (hp33).

**Why a temporary holder cannot be written by a later statement:**
`holdsPastDrop` returns false for any statement temporary that no flow
views. That would be wrong if an outer statement's temporary could
outlive an inner statement that writes a view into it. That cannot
happen:

- block-valued `if` and `match` appear only as a binding value, a
  return value, or a tail, never as an argument;
- headers drop their temporaries before the body runs;
- inner statements cannot name an outer temporary.

## Findings

### Low 1 (comment): `holderLive`'s doc comment was merged into `holdsPastDrop`'s

`src/ownership.zig:1407-1422`. dff5d589 inserted the new doc comment
under `holderLive`'s existing one. As a result, `holdsPastDrop` carries
both paragraphs, starting with "Whether the value var `id` holds may
still be used…", and `holderLive` (line 1441) has none. Move the first
paragraph back above `fn holderLive`.

### Low 2 (diagnostic, not from these commits): `namedLeaf` calls a part of a made value "a value a name holds"

Probe: `fuzz/p/brmix__bump.rig` and the other 47 `brmix__*` programs.

```
cd /Users/shreeve/Data/Code/rig-seam2b && bin/rig run …/fuzz/p/brmix__bump.rig
```

On `!(mkpair(3).a if c else mk(5)).bump()` the compiler says "cannot
lend … to write: it may be `mkpair(3).a`, a value a name holds". No
name holds `mkpair(3).a`. `typecheck.namedLeaf` tests `hasStorage()`,
which includes `part_of_made`.

The rejection itself is safe: lending the branch would copy the part
out of `mkpair(3)`'s temporary. Only the wording is wrong. It should
say "a part of the temporary `mkpair(3)`", or `namedLeaf` should be
split by kind.

### Low 3 (diagnostic): `!lib.ok()` on a module function returning `Bool` gets the lend hint, not `not`

Probe: `diag/d05_bool_module.rig`. The program `if !lib.ok()` gets "write
`!(lib.ok(...))` to lend that value, or drop the `!`". Following that
hint leads to the next rejection ("`!` lends to write; use `not` for
negation"). `fieldCallSigil` already treats a callee returning `Bool`
as the negation habit. The new branch in `synthMemberCall`
(typecheck.zig:6877) should do the same.

Every other new diagnostic case behaves well:

- each form is reported once: `grow(!lib.mk())`, `x = !U.make()`,
  `!lib.E.a(...)`, `!Wrap[Int].make(3).bump()`;
- the parenthesized forms run (d11);
- `?` and `<` keep their old messages (d12, d13);
- a local or parameter named like a module is rejected earlier by the
  shadowing rule (d01, d03), so `!x.f().g()` on such a name cannot be
  misread;
- `!.a(...)` gives the usual "needs a known enum type" (d04).

### Low 4 (diagnostic wording): the new `as` hint names a header temporary that does not hold the view

Probe: `diag/d14_as_hint_unrelated_temp.rig`. For
`if pick(!h, ?S(n: 1)).o as x`, the view comes from `h`, but the
message says "`as` over a write view a temporary of the header holds:
bind `S(n: 1)` to a name first". `firstStmtTemp` returns any temporary
of the header.

The advice still works: d15 follows it and runs. Only "holds" is
inaccurate. Wording such as "a write view in a header that makes a
temporary" would be accurate.

## Not new, seen again

- **Round-1 Low 4.** A call-held receiver inside a branch keeps its
  loan (the 16 `tern*__meb` rejections).
- **t05 / hp29: the `swap` of two temporaries' `!T` fields is still
  rejected while the oracle accepts it** ("stricter"). The named form
  hp32 is rejected the same way, so this is not a temporary-versus-name
  gap and is outside dff5d589. On named holders, the `swap` of view
  fields also gives a confusing loan error (hp34). That case predates
  this branch.

## Oracle

The oracle shows no "unsound" differences on any probe:

- `prod=accept ref=unknown` on the swap, write lends and receivers
  through branches (e06–e16);
- "stricter" only on hp19, hp20, hp29 and hp32.
