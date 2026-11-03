# Row 33C, expert review: soundness and fit with CORE

Reviewer lens: soundness and fit with CORE. Read: draft 1, CORE (origin/main) §1, §2, §3, §9, §10,
INTERNALS "What an expression hands over", "Header subjects", "Call origins", and the deciders in
src/sema.zig and src/typecheck.zig at 928b44bf2. Every claim marked *probe* was run with the
baseline `rig` at 928b44bf2 and, where it says so, with `bin/rig-oracle` (the CORE-only checker).
The probe programs are in
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-language-analysis-aa0a1d/67c60f05-c7b3-4699-a1a3-55125acb3379/scratchpad/c33/`.

## Summary

The draft names a real gap and the join order is right. Four things need to change before it goes
to the owner:

1. **The fact is about loans, not about kind.** The draft's first row ("a type of the plain or
   owning or handle kind: `none`") is wrong. An owning object can hold a view (CORE §1: an object is
   owning if any part owns, *even when* another part is a view; the `Reader` of sentence 7 holds a
   `String` and a `?List[Int]`). So can `^?v` (§5, "a holder of a read view carries its loan") and
   `*T` (sentence 9, "a `*T` carries the loans of what it holds"). The row that decides `none` must
   be CORE §9's per-type fact *may hold a loan*, not the kind.
2. **The path rows are wrong in both directions.** "A place of the view kind: `place`" is wrong
   for `first_list(?mk())[0]`, which `handsOver` calls a place (a path through a view) but which
   lives in `mk()`'s temporary. "A part of a made value, of the view kind: `made`" is wrong for a
   read-view field of a made value, `hold(?ls).items`, which by sentence 7 carries the field's
   loans and none on the holder. *Probe d2b:* the compiler rejects `v = hold(?ls).items`; the
   oracle accepts it (`stricter d2b.rig main prod=reject ref=accept`); and the method form of the
   same thing, `hold(?ls).all()` with `from @items`, is accepted today (*probe g1*). That is two
   deciders of one fact disagreeing, which is exactly what row 33C exists to end.
3. **The reader list names the wrong functions.** The nine deciders the draft lists all take a
   `TypeId`; they answer type questions and should stay. The expression-level re-deciders are
   others: typecheck's `isTemporary`, the `for` rule's `placeOf(source).named()`, `holdsHeld` /
   `makesTemps` (a syntactic walk for any temporary in a held base), `tempBase`, and the
   ownership checker's loans for a part of a temporary.
4. **"All fail today" is not so.** The `match` and `if … as` siblings already pass (*probes c5,
   d4*): only a `for` over a List of moving elements fails, because that rule asks whether the
   source's place is *named*, not what it hands over. The same rule rejects paths through a
   returned view that `handsOver` already calls places (*probes c1, c2*). These are the real
   failing set (below).

The loop example is sound to accept, and CORE already says why (sentence 6 with §3's "taken"
rule); only §3's status note fails to claim it.

## 1. The shape

### Is `none` / `place` / `made` with `made` over `place` over `none` right?

Yes, once it is stated as **what the loans a value carries name**, not "what its value views".
That reading follows from CORE with no new rule:

- Sentence 6: a loan travels with every view that carries it, into a field, an array, an
  optional, a closure, a result. So a value carries the union of its parts' loans.
- §3: a view of a temporary may be used only within its statement. So one loan on a statement
  temporary is enough to end the value with its statement: `made` dominates.
- A loan on a place is still a loan: `place` over `none`.

The join is the union of loan sets seen through the map {a temporary's loan, a place's loan, no
loan}, so it is a lattice homomorphism. It is not a new rule.

Stated so, the fact is orthogonal to the two facts the readers already have: whether the value is
a view (the type's kind, per type, CORE §1 and §9) and whether it is an owned temporary
(`handsOver`'s kind plus that type fact). The draft's three values mix the two ("`none`: it owns
what it holds"). The readers need them apart: an owning `Holder` made by `wrap(?String("x"))` is
an owned temporary *and* views a temporary, and a header that holds it for the construct must
reject it for the second reason, not the first (*probe f3*).

### One paragraph, no exception list (CORE §10)?

Yes, with the compositional list below: four clauses, each one a CORE sentence, and "everything
else joins its parts". The draft's table has seven rows, two of them wrong; the rows below
replace it.

## 2. Revised text for the draft

### "The fact" (replaces the draft's section)

> **What its loans name:** `none` (it carries no loan), `place` (every loan it carries is on a
> place: a binding, or a path from one), or `made` (a loan it carries is on a value made in its
> statement, which the statement's end drops). A value carries every loan its parts carry
> (sentence 6), and one loan on a temporary ends it with its statement (§3), so the join is
> `made` over `place` over `none`.

| The expression | What its loans name |
|---|---|
| one whose type may hold no loan (CORE §9, per type, at the instance) | `none` |
| a constant, a function, an `Enum.variant`, a literal (`"abc"` as a `?String` too) | `none` |
| a binding's name: a local, parameter, capture, or self | `place` |
| a lend of `x` whose type is a view: `?x` of a read view is that view (§4), `!x` of a held `!T` lends it on | what `x` names |
| any other lend of `x`, or its slice | where `x` lives, joined with what `x` names. Where it lives: `place` if its path starts at a binding, `made` if at a made value, and, past the last view on the path, what that view names |
| a path `b.f`, `b[i]`, read rather than lent | what `b` names |
| a call | the join, over each input whose loans the result carries (sentence 7, its recorded origins), of what that input names. An input is an argument, counted as the lend it is where a view goes unwritten (sentence 4); self, counted as the lend its method takes, except that a `from @path` ending at a read-view field counts only what self names; and the called value, when the call calls a value rather than a named function. Each of several results has its own answer, from its own type; the call's is their join |
| `+x`, `<x`, `*<x`, `^<x`, and an erasure of `x` to an API object | what `x` names |
| a constructor, an array, `*S(...)`, `^S(...)`, an optional or enum payload, a closure literal (its captures) | the join of its parts |
| branches, a `match`, a block, a loop's value | the join of its leaves and tails; a leaf that jumps adds nothing |
| a jump, or no value | not asked |

A read view of a value that copies, read where a value is expected, is still a view here: where
it is copied out is a decision about the context (`sema.copies`), not about the expression. (Kept
from the draft.)

### "What changes for programs" (replaces the draft's section)

> Only accepts more. A header reads in place a subject that is a view a call returns, or a path
> through one, as it reads a place: a `for` over a List of owners included, which today asks for
> a named place. A read-view field of a made value is copied out with its own loans, as a
> `from @field` method's result already is. Nothing accepted today is rejected: every new
> acceptance is one where the subject's answer is `place` or `none`, and a `made` answer is
> rejected exactly as the ownership checker rejects it today.

### "Who records it, who reads it" (replaces the reader list)

- **Records:** sema, beside `handsOver`, from `typeOf` at the instance, the per-type *may hold a
  loan*, the call's `CallParams` (`origins.result`, `self_paths[].via_view`), and `readViewField`.
  It is one exhaustive switch over the IR's kinds, as `shapeOf` is.
- **Reads, in place of a re-decision:**
  - typecheck's `isTemporary`: it becomes "a lend of `e` would name `made`";
  - the `for` source rule's `placeOf(source).named()`: reject only an owned temporary List (the
    §3 planned case), or a subject whose answer is `made`;
  - `holdsHeld` / `makesTemps`: a held base is refused when *its* answer is `made`, not when any
    temporary appears anywhere inside it;
  - `tempBase`, and `rejectHeaderCopy`'s `firstStmtTemp` where it stands in for "views a
    temporary";
  - the ownership checker, where it gives a part of a temporary its loans (the d2b rejection).
- **Stay type-level:** `isReadOrWriteView`, `isViewType`, `holdsMarkedView`, `mayHoldMarkedView`,
  `mayHoldView`, `holdsViewOnly`, `viewHeldAsPointer`, `isErasedView`, `readsAsValue`. Each takes a
  `TypeId` and answers a question about a type.
- **The safety rule:** the ownership checker never accepts *because* the answer says `place`. It
  computes loans as it does now, and under `-Dself-check` it asserts that every loan it gives a
  value on a statement temporary is matched by a `made` answer, and the reverse. Typecheck and
  storage may accept on `place`; the ownership checker is the backstop that keeps "accept means
  correct" if sema's answer is ever too weak.

### "CORE §9, as it would read" (replaces the draft's bullet)

> - **Per expression, one classification** of what it hands over: a place, a made value, a lend,
>   branches, or a jump; and what the loans it carries name: nothing, places, or a value made in
>   its statement, joined over its parts as sentences 6 and 7 carry them, a temporary's over a
>   place's over none *(built)*; whether the value lives for the whole program *(planned)*.

### CORE §3, its status note (new; the draft omits it)

The draft's example is a `for` over a view a call returns. §3 says a value a `for` header binds
is taken, and its status note claims that only for `if … as`, `while … as`, `match`, and "a `for`
over plain elements". Under "docs claim only what runs", the note must change in the same edit:

> *(built* for `if … as`, `while … as`, `match`, a `for` over plain elements, and a `for` over a
> view a call returns, which reads in place what the view sees; *planned* for a `for` over a made
> List of owners, which is bound to a name first today.*)*

The draft's loop becomes an ordinary §3 example with an `output` block (`a`). The existing
`rig pending` `for x in names()` stays pending: that one is a made List of owners, not a view.

### "Tests" (replaces the draft's list)

Failing today, to pass (each a `test` case; probe file named):

- the draft's loop (a1), and `for x in ?first_list(?ls)` (b3b);
- a path through a returned view: `for x in first_list(?ls)[0]` (c1), `for x in get(?b).items` (c2);
- a write view result: `for x in !first_w(!ls)`, writing each element (c3);
- a generic result at a view instance: `for x in id(?ls)` (c4);
- a stack closure's view result: `f = |?ls| ?ls`, `for x in f()` (e1);
- a read-view field of a made value: `for x in hold(?ls).items` (d1), `v = hold(?ls).items` (d2b),
  `for x in hold(?ls).all()` with `from @items` (g3).

Passing today, kept as guards: `match pick(?v)` over owning payloads (c5); `if opt(?ls) as l` (d4).

Rejected today, still rejected (`fail`):

- `for x in first_list(?mk())` (b1): a view of the temporary `mk()` outlives its header;
- `for x in first_list(?mk())[0]` (b2), whose message today names the wrong temporary
  ("walk the temporary `first_list(?mk())`"): with the fact it names `mk()`;
- `if wrap(?String("x")) as h` (f1), `match wrap(?String("x"))` (f2): an owning value that views a
  temporary;
- `v = hold().all()` with `from @items` on an owned field (g2): `made`;
- the loan lasts the loop: `!ls.push(...)` inside `for x in first_list(?ls)` (b4);
- no element is taken through the view: `for x in <first_list(?ls)` (b5), by the view rule once the
  named-place test is gone;
- `s: ?{Shape} = ?mk()` (i2): an erasure keeps its operand's answer, its block-local copy
  notwithstanding.

The oracle: run it on each. It already agrees on b1 and e2 and accepts d2b, so d2b's line in
`test/oracle/differences` (if it has one) goes, not comes.

## 3. Is accepting the loop sound?

Yes. What has to hold:

- **The loan.** `first_list(?ls)` carries a read loan on `ls` (sentence 7: the result carries the
  loans of `lists`, whose type could hold what it views; the callee's `?lists[0]` is a loan on the
  path so far, which is `lists`, so at the caller a loan on `ls`). The header takes the result
  (§3: "a value made there that … `for` binds is taken"), so the view lives in the header's
  hidden binding through the body, and each `x` is a view through it carrying the same loan.
  Sentence 6 then makes the loan last until the last use of every view carrying it: the loop's
  last step, through `break` and early exits too. *Probe b4* shows the ownership checker already
  keeps it: `!ls.push(...)` in the body is rejected, with the note pointing at `?ls` in the header.
- **Nothing is made to drop.** The taken value is a view (kind, per type), so the header owns
  nothing, and no element may be taken through it. `for x in <first_list(?ls)` is rejected today
  only by the named-place test (*probe b5*); once that test reads the fact, the existing view rule
  ("would move the elements out of a List that … only views") must still reject it, so it is a
  `fail` case below. The elements bind as `?String`, as for `?ls[0]`.
- **What CORE already says.** Sentence 1 (a header's subject reads in place), §3 (header takes a
  made value; its temporaries end with the header, what it binds lives through the body),
  sentence 6, sentence 7. No new sentence; only §3's status note.
- **The one emit risk.** A header with temporaries is emitted as a labeled block whose defers end
  them. The view must leave that block as a value (a pointer, or a fat pointer for a slice), never
  as the address of a slot inside the block (docs/internals/weak-spots.md: never take the address
  of a Zig temporary no storage fact names). The storage plan should hold the made view exactly as
  it holds `y` in `y = first_list(?ls); for x in y`, which runs correctly today (*probe b3c*). Emit
  gains no decision of its own: it reads the storage fact.

## 4. Corner cases, each with its answer

| Case | Answer | Why |
|---|---|---|
| write view result, `first_w(!ls)` → `!List[String]` | `place` | sentence 7; the result holds a write view, so the write loan on `ls` stays while it lives |
| `(!t).edit(0)` → `(!Int)?` `from @`, `t` a binding | `place` | self is a binding; §5 example |
| `(!mk()).slot()` → `!Int` | `made` | self is a made value; usable within the statement only (sentence 4) |
| generic `id[T](x: T) -> T` at `T = ?List[String]`, `id(?ls)` | `place` | the type at the instance may hold a loan; `T`'s origins carry `x` |
| the same at `T = Int` | `none` | the instance's type may hold no loan |
| `?{A}` erased from `?v[0]` | `place` | an erasure keeps its operand's answer (CORE §4, "carries every loan") |
| `?{A}` erased from `?mk()` | `made` | the same; *probe i2* rejects it today, correctly |
| a call through a `?{A}` | by the API's `from` | sentence 7, §4 |
| several results, `-> (!Int, Bool)` | per result: `place` and `none`; the call: `place` | sentence 7, "Several results": each result carries its own type's loans |
| `from @items`, `items: ?List` read view, self made: `hold(?ls).all()` | `place` | sentence 7: carries the loans self holds and none on self (*probe g1* accepts) |
| `from @items`, `items: List` owned, self made: `hold().all()` | `made` | a loan on the path of a temporary (*probe g2* rejects) |
| `hold(?ls).items`, read-view field, read | `place` | a path names what its base names; sentence 7's read-through rule. Today rejected; oracle accepts |
| `?hold(?ls).items` | `place` | a read view of a read view is that view (§4) |
| `?mk().own` | `made` | a lend of a part held by value in a temporary |
| `first_list(?mk())[0]` | `made` | a path names what its base names; `handsOver` says `place`, which is why the answer cannot be read off the kind |
| stack closure `\|?ls\| ?ls`, its literal | `place` | its captures are places (§7: a capture of a path is `w = ?p.a`) |
| a call of that closure, `f()` | `place` | the called value is an input (*probe e2*: the result carries the loan on `ls`) |
| an owned closure, `*\|...\|`, and a call of one with no lent argument | `none` | its environment holds no loan (sentence 9); its result views only what the call lent it (§7) |
| a `?String` literal, `"abc"` | `none` | a `Static`, read as a `?String`, carries no loan |
| a binding `s: ?String = "abc"` | `place` | sema has no flow facts; `s` may be re-pointed. Conservative, and no reader in this change tells `none` from `place` |
| a call with no input its origins carry (`from static`, `os.args()`) | `none` | sentence 7 |
| `x ?? return`, `e!`, `e?` | what `x` / `e` names | a jump leaf adds nothing |
| `m.get(k) ?? ?String("none")` | `made` | the join; CORE §4 already says to clone it, `+(...)` |
| `m.get(k) ?? 0` | `none` | its type is `Int` |
| `a if c else return` with every leaf jumping | not asked | a jump |

## 5. Open question 1: "lives for the whole program"

**Default: it stays planned, and `none` is worded "carries no loan" so that, if it is ever built,
it is `none` at a view type and needs no fourth value.**

- No reader in this change tells `none` from `place`: every reader asks only whether the answer
  is `made`. A value no reader asks for is a claim the docs cannot test (North Star 6).
- Its historical consumer was the revamp's step 6.2 (records/revamp/r3/audit-steps3-6.md):
  whole-program summaries letting a function store a `?String` parameter in a `Cell` when every
  caller passes static text. CORE replaced that with a type rule: a `Cell` keeps text only as a
  `Static`, and "nothing converts a `?String` to a `Static`" (§4). So the planned fact has no
  consumer CORE still wants.
- For a binding, sema can only say `place` (no flow facts), so "lives for the whole program"
  would be true only of literals, constants, and calls with no carried input: exactly `none` at
  a view type. Nothing more is gained by naming it.

If the owner would rather close the planned clause, the alternative is to strike it from §9 and
add to the paragraph: "a view whose loans name nothing lives for the whole program". That claims
nothing new and needs no code; I would still not do it in this change.

## 6. Decisions, each with a default

1. **The fact means what the loans a value carries name, and its `none` is decided by the type's
   *may hold a loan*, not its kind.** Default: yes. The kind row calls an owning `Reader`,
   `^?v`, and `*T` `none`.
2. **Adopt the compositional positive list above** (names, lends, paths, calls, the rest joins its
   parts). Default: yes. It is one paragraph, follows sentences 4, 6, 7 and §3, §4, and fixes both
   wrong path rows.
3. **A path names what its base names; a read-view field read out of a made value is not `made`.**
   Default: yes. The oracle accepts `v = hold(?ls).items` and the compiler rejects it, while it
   accepts the `from @items` method form.
4. **A call's inputs include the called value, and an argument read in place where a view goes
   counts as its lend.** Default: yes. Otherwise a closure's view result (*probe e2*) and
   `first_list(ls)` would be `none`.
5. **Several results get an answer each; the call's is the join. A jump leaf adds nothing.**
   Default: yes.
6. **Accepting the loop is sound; edit §3's status note to claim "a `for` over a view a call
   returns", and make the draft's loop an ordinary §3 example.** Default: yes.
7. **Replace the draft's reader list with the expression-level re-deciders** (`isTemporary`, the
   `for` rule's `named()` test, `holdsHeld`/`makesTemps`, `tempBase`, the ownership checker's
   loans for parts of temporaries). The nine named deciders stay type-level. Default: yes.
8. **The ownership checker never accepts on the answer; `-Dself-check` asserts it agrees.**
   Default: yes. It keeps "accept means correct" independent of sema's summary.
9. **Correct the test list** to the failing set above; `match` and `if … as` siblings are guards,
   not failures. Default: yes.
10. **"Lives for the whole program" stays planned.** Default: yes, with `none` worded "carries no
    loan".
11. **Emit gains no decision.** Default: yes. The storage plan holds a made view like a named one,
    and the header block yields the view's value, never a slot's address.
