# Row 33D, expert review: soundness and fit with CORE

Reviewer lens: CORE and soundness. Read: draft 1 and its brief; docs/CORE.md whole (at main
ad5d9b043); SPEC §7 "Evaluation order within a call" and the operand paragraph after it;
docs/internals/weak-spots.md; in src/ownership.zig `indexUses`, `holderLiveDepth`, `liveFrom`,
`walkStmtValue`, `endWriteLends`, `keepViewTemps`, `carryAs`, `walkIf`, `walkMatch`, `walkFor`,
`holdBase`; in test/oracle/lower.zig the call arguments (`arg_how`), `readThrough`, `readOpt`, and
the binary operators; test/oracle/differences; test/matrix.py's `eq`, `eq_then_write`,
`arg_then_write` forms. Every claim marked *probe* was run with main's `bin/rig` and
`bin/rig-oracle` from `~/Data/Code/worktrees/rig/core-33d-read` (ad5d9b043). My probes are in
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/61e6bc21-7c82-43f3-8978-0dbbd8206817/scratchpad/x/`;
the draft's are in `.../scratchpad/p/`.

## Summary

The direction is right and CORE allows it: sentence 6 already says a loan ends at the last use of
its views, "not until the lend's line ends". But the draft is not ready for the owner. In order of
weight:

1. **Main has a live use-after-free in exactly this class.** A condition written after the value
   it guards runs first, and liveness by source position calls a view dead there. `s = ?v[..]`
   then `print(s[0]) if grow(!v)`, `print(s[0] if grow(!v) else 0)`, `n = s[0] if grow(!v)`, and
   `return s[0] if grow(!v)` are all accepted on main, all crash under `RIG_SANITIZE=1` ("use of
   freed memory"), and the oracle rejects all four (*probes i4, j1, j3, j2*: `DIFF ...
   prod=accept ref=reject`). No test covers the form, so the suite never sees the difference.
   This is a North Star 2 bug today, independent of 33D; it should land first, as its own fix.
2. **The operand clause contradicts SPEC and the differences file, and the draft's own gain list.**
   It splits operands by `sema.readsAsValue` (scalars and plain enums only). SPEC §7 already
   states the in-statement order rule by type: a view, a value sharing storage, or what a write
   view reaches is read in place and stays in use until the call ends or the operator's later
   operand has run; plain data is copied whole where it is read. Under the draft's split,
   `int.eq_then_write.{read_view, write_view, destructure_write}` (`(r) == pokev(!a)`, classified
   `ref-gap`, the compiler right) become accepted, so three `ref-gap` lines go stale; and
   `plain.eq.*` and `array.eq.*` (4 of the 8 claimed `*.eq.*` gains) stay rejected, since a
   `!P` or `![3]Int` operand would be "used until `==` yields" as a write loan while `a` is read.
3. **The CORE text belongs in §6, not sentence 6.** Sentence 6 already applies within a
   statement. What CORE lacks is §6's order rule for operators and the copy/in-place split, which
   today live only in SPEC; the oracle, written from CORE alone, cannot learn them until CORE says
   them.
4. **(C) is misdiagnosed, and its CORE clause is unsound as worded for `for`.** c2, c3, and
   `match_arm_writes` are kept rejected by `temps` (the header's call result's loans, which
   `endWriteLends` adds to `temps`, outliving the header), not by the hidden var: `walkMatch`
   already clears its `hold` var when an arm is chosen. The clause "a value a header holds is used
   by its header, guards, and patterns, and then only by its drop" is false for a `for`, which
   reads its source at every step (CORE §3: "`ls` stays lent while the loop runs").
5. **"Nothing accepted today is rejected" is false** once item 1 is fixed: the walked-order rule
   rejects the four programs above. The release-notes and Trig-note rule applies.

Revisions are listed at the end.

## 1. Does each clause follow from CORE?

| Clause | Verdict |
|---|---|
| "Within a statement, a use is a point in the order it runs." | Follows from sentence 6 plus §6's evaluation order. Sentence 6 says "not until the lend's line ends" in the opening section, so it already holds within a statement. |
| "An operand read as its value (… sentence 1) is used where it stands." | Wrong citation and the wrong split. Sentence 1 says a bare read view copies **the view**, not the value; only a bare write view of a copying value reads the value it sees. §4's copy-out ("a plain object, array, or optional as a number is") is about where a `T` is expected. Neither gives `readsAsValue`'s scalars-only line, which weak-spots records as a compiler divergence, not a rule. |
| "Any other operand, argument, or self is used until its operation finishes: a call until it returns (§6), an operator until it yields." | Calls: §6 decides. Operators: CORE says nothing; SPEC §7 says it ("the left operand of `==`, `!=`, or an ordering operator while its right operand runs"). Adding it to CORE is a real addition. It is right, but the draft should say it adds a rule rather than "no new rule". |
| "A value that carries the view on (a call's result, a constructor, a branch, a binding) uses it for as long as that value is used." | Follows from sentence 6 ("wherever that view went") and sentence 7. |
| "A binding's views are used until its last use in that order, or through a loop it was declared outside of." | Follows; the loop part is built (`loopStartFrom`). It omits defers: a use in a `defer` or `errdefer` counts where the defer runs, at every exit of its scope (§7). The code has it (`defer_used`); the text must too. |
| "A value a header holds is used by its header, guards, and patterns, and then only by its drop …" | Right for `match` and `if … as` (a `match` reads its subject until an arm is chosen, §3). Wrong for `for`: CORE §3 keeps a loop's source in use while the loop runs, unless the header copied it. |

**The proposed sentence 6 addition** ("within a statement too, in the order it runs (§6)") is
not wrong, but it is not needed and it sits in the wrong place. Sentence 6 is about how long a loan
lasts, and it already says "not until the lend's line ends". The order is §6's ("Evaluation
order"). Put it there, as SPEC already has it, and extend it to operators. Suggested replacement
for §6's second paragraph:

> A call evaluates its self and arguments left to right, then runs, and an operator its operands
> left to right, then yields. What an earlier argument or operand reads in place (a view, a value
> that shares storage its place owns, or what a write view reaches) stays lent, to read, until
> the call returns or the operator yields, so a later one can't change it. Plain data read from a
> place is copied whole where it stands, and keeps nothing lent. A write lend of a method's self
> acts as a read loan until the call starts, so `!v.push(v.len)` works; a write lend in any other
> argument is a write loan at once, so `grow(!v, v.len)` is rejected.

**§10 fit.** That is one paragraph, with no exception list, and it follows the type: a view, a
value that shares storage, or plain data. The draft's version follows a compiler classification
(`readsAsValue`) that is narrower than CORE's own copy rule. That fails "rules follow the value's
type" in spirit, because a `?Int` and a `?Point` would differ by how emit happens to read them.

**What the replacement decides, checked against the record:**

| Program | Replacement | Draft | Record |
|---|---|---|---|
| `print(w == a)`, `w = !a`, `a`: Int, Simd, plain object, [3]Int | accept: `w`'s write loan ends at its read, and `a` stays lent to read | accept Int and Simd; reject plain and array | the 8 lines are `prod-strict` (CORE allows) |
| `(r) == pokev(!a)`, `(w) == pokev(!a)`, `a: Int` | reject | accept (3 `ref-gap` lines go stale and the run fails) | `ref-gap`: the compiler is right |
| `print(r, poke(!a))`, every type (`arg_then_write`) | reject | reject | `ref-gap` |
| d3: `print(r == bump(!a))`, `a: [3]Int` | reject | reject | the oracle accepts today |
| b2: `print(w == a)`, `a: String` | reject: a write view of a value that does not copy is not a read | reject | the oracle rejects |
| b1, c1: `!v.push(Item(n: x.n))` | accept: `x.n` is plain data copied into a field | accept | `prod-strict` |
| `write_result_whole`: `print(firstw(!v).n, v.len)` | accept | accept | `prod-strict` |
| h6: `print(x.n, poke(!v))`, `x = ?v[0]` | accept: plain data copied whole, as `print(v.len, grow(!v))` in SPEC | accept | the oracle accepts |
| h4: `add(r, poke(!a))`, an `Int` parameter | accept: copied out to a parameter that takes it (§4) | accept | the oracle accepts |

Zig agrees with the emitted order: `r.* == poke(&a)` loads the left operand first, and
`std.meta.eql(q.*, bump(&p))` copies `q.*` first (*probe order.zig*, Debug and ReleaseFast). So
accepting a copied operand is sound. The rejections above are SPEC's meaning, not a memory
question.

## 2. Holes

**H1, live on main: a condition written after the value it guards** (*probes i4, j1, j2, j3*).
`walkIf` walks the condition as its own statement (`walkStmt(cond)`). Inside it, `liveFrom` is the
condition's start, which lies after the then-value's text in `x if c else y` and in `stmt if c`.
So a binding whose last use is in that value counts as dead while the condition runs:

```rig
fun grow(v: !List[Int]) -> Bool
  for i in 0..100
    !v.push(i)
  true

sub main()
  v: List[Int] = List()
  !v.push(1)
  s = ?v[..]
  print(s[0]) if grow(!v)      # accepted on main; RIG_SANITIZE: use of freed memory
```

The ternary, the binding, and the `return` forms fail the same way. The draft's walked-set idea
fixes this class. Its claim that the rejected design "accepts `print(w.n) if poke(!a)`" understates
the problem: main accepts it now. Fix it first: a small change to `walkIf` (the condition's
liveness starts at the enclosing statement's start), with these four as `fail` cases, then land
33D on top of it.

**H2: the walked set must be state the walk rewinds.** Every place that re-walks code (the loop
fixpoint's rounds, `rewind`, and branch joins) must restore it. A header or arm walked as a
nested statement must also leave its uses marked walked in the enclosing statement. If one does
not, the result is conservative (the binding is still live), which is safe but loses gains. Name
it in the draft.

**H3: what a call holds when a binding dies at its argument.** Under (B), `x` dies at
`show(x, poke(!v))` with `show(a: ?Int, …)`, so the call must hold `x`'s loans until it returns.
The draft says so; this is the main way the change could go wrong. Today the oracle *also*
rejects k4 (`show(x, poke(!v))`), so it guards the view-parameter case. It does **not** guard the
`print`/`String` case (it copies out there). Hence §3 below.

**H4: write lends of self.** `!v.push(x)` with `x: ?Item` and `push(Item)`: `x` is copied at the
argument, then the self's write starts. This is sound only if Zig copies a by-value struct
argument before the callee runs. It does (*probe alias.zig*: the callee writes the aliased element
first and the parameter keeps the old value, in Debug, ReleaseSafe, and ReleaseFast). Still, add
g2 (`x = ?v[0]` then `!v.push(x)` with a 4-field `Item` and a growth) as a sanitizer test. A self
that is a binding view and a later argument that writes its owner (`!w.push(poke(!v))`) must stay
rejected (k6, both checkers reject today).

**H5: several results.** v07 (`v, s = mk(?s)`, `v` never read again) is sound to accept: `v`
takes result 0 before `s` is bound, and nothing reads it after. `s, v = mk2(?s)` (bind `s` while
the untaken result views it) must stay rejected; it is today, by both checkers (*probe i2*). The
`review-results-f01/f04/z04/z05` lines are `ref-gap`: an old value's `drop` body reads what an
earlier target replaced. Only the compiler guards them, through `dropRunsBody` liveness. Keep them
as `fail` guards.

**H6: `_ =` discards.** Out of scope, correctly. A discarded result with a `drop` body keeps its
views to the statement's end (Core "Several results"), and that is unchanged.

**H7: closures.** `print(f() + poke(!a))` with `f = |?a| …` is sound to accept: the call reads `f`
until it returns, and `f` has no later use (*probe h2*: the oracle accepts it). `print(poke(!a) +
f())` stays rejected (h3, both checkers). A closure literal lent to a call is an argument, held
to the return.

**H8: defer and errdefer.** `x = ?v[0]`, `defer print(x.n)`, `!v.push(Item(n: x.n))` must stay
rejected (h1, both checkers). The clause text must count a deferred use where the defer runs.

**H9: `!`, `catch`, `??`, branches.** Both checkers walk these in run order: the handler after
the call, the right side of `and`/`or` only on its path, and both arms of a branch, which run
exclusively. One caution: a branch whose value carries the first arm's loans must keep them in
`temps` while the second arm is walked, because the parent has not finished. That is conservative
and matches today.

**H10: loops in a statement.** A binding declared outside a loop is live through it
(`loopStartFrom`), including for a loop used as a value inside a statement. d1 stays rejected.

**H11: hidden statement temporaries.** These are not unsound, but the draft does not cover them.
`holderLiveDepth` calls every hidden var live, so an owning temporary with no `drop` body that
holds a view keeps it lent to the statement's end: `add(wrap(?v).first.n, poke(!v))` is rejected
by main and accepted by the oracle (*probe k1*). With a `drop` body, both checkers reject (k2),
correctly. That is a fourth place where loans last a whole statement (beside `temps`, bindings,
and header-held bases). Either include it (a hidden var is live while its construct reads it, or
while its drop could run a body: `holdsPastDrop`'s test, applied during the statement and not only
at the drop), or list it as not covered.

**H12: tasks.** A task's call result keeps every argument loan in its `Value` (`carryAs` returns
`v` for a task), so shrinking `temps` to the value is safe. Keep it that way.

## 3. The oracle

The draft is right that the oracle must learn the order rule in this change, and more right than
it says. The oracle is the independent check for exactly the loans this change ends early, and
for the `print`/`String` and operator cases it agrees with whatever the compiler does. Two code
sites cause this:

- **Calls** (`lower.zig` about line 3840): `if ((arg_how == .take and …) or all_read) v = try
  self.readThrough(v, …)`. `readThrough` copies a hidden view temp of a copying type out at the
  argument, so for `print`, `String`, and every other `all_read` built-in, the view dies at the
  argument rather than at the call. View-parameter arguments (`.view`) are already held to the
  call, which is why k4 is rejected.
- **Operators** (about line 2553): both operands go through `readOpt`, which calls `readThrough`.
  The comment there cites SPEC §7, not CORE.

The CORE text that decides it: §6 "A value an earlier argument reads stays lent until the call
returns", and sentence 4 "`print` and `String` read their arguments the same way" (as a view lent
for the use). That covers calls. For operators, CORE says nothing today, so the oracle can learn
the operator rule only after CORE gains the §6 sentence above. That is one more reason the text
belongs in §6.

**Size.** In lower.zig, `print`/`String` arguments that read in place keep the view var in the
call's `reads` instead of copying it out. `all_read` value built-ins (`min`, `max`, `hash`, …)
keep the copy, so the oracle needs those split. The left operand of `==`, `!=`, and the ordering
operators is used at the `make`. A bare write view of a copying value becomes a read loan there.
That is roughly 40–80 lines, plus regenerating `test/oracle/rejections`. Lines leaving
`differences`: the 26 `ref-gap` lines that cite Core §6 (23 `arg_then_write` and 3
`eq_then_write`), which become agreements. The real cost is any new `prod=accept ref=reject`
those lines expose, each a possible compiler hole to fix rather than allowlist.

**Order.** Land the oracle change first, as its own PR (tests and tools only, so no light gates),
so the compiler change is checked against it. Also write into the process: in this change, a
`ref-gap` line going stale is a soundness alarm, never a line to delete. Only `prod-strict` lines
may be deleted when FIXED.

## 4. Does (C) belong in this row?

Split it in two.

- **`match` and `if … as`: in this row.** c2, c3, and `match_arm_writes` are (A) at a header.
  The subject's call result loans sit in `temps` (`endWriteLends` re-adds the result's loans), and
  `temps` lasts until the whole `match` statement ends, through every arm. CORE §3 already decides
  it: "A header's temporaries end with the header; what the header binds lives through the body."
  The fix is to shrink `temps` after the header to what the held value and the bindings carry, as
  `walkMatch` already does for a lent place. The `hold` var then ends at arm choice, which is
  built. The true hidden-var case is a held base, `match pair(?v).tag` (*probe k3*: main rejects,
  the oracle accepts), together with H11. No new CORE text is needed.
- **`for`: its own row.** t05 is not a liveness fact. The loop holds the base `(a if c else b)`,
  and whether that base is used past the header depends on whether the loop copies the part:
  emit writes `for (@as(*A3, …).arr) |x|`, and Zig copies an array operand (*probe forarr.zig*),
  but a List part is read in place at every step. Today that decision lives only in emit and Zig
  semantics, against North Star 4. It needs a recorded fact ("the loop copies its source in the
  header", by type: a plain part) before the checker can end the base's loans. Guards that row
  must keep: f1 (`for x in first(?ls)` with `!ls.push`) and f4 (`for x in hold(?v).items` with
  `!v.push`), both rejected today by both checkers.

## 5. Other corrections

- t05 as probed in `p/t05.rig` is not the listed program. The real case
  (`test/rig/probes-22.rig.test`, a loop over `(a if c else b).arr` that pushes `xs`) is still
  rejected on main (*probe t05r*), and so is the simpler `for x in a.arr` (t05s). Neither is a
  33D gain under the split above.
- The gain list should read: `match_arm_writes`, `write_result_whole`, the 8 `*.eq.*` lines (all
  of them only under the §6 rule above), v07, c2, c3, b1, c1, k3, and k1 if H11 is taken. It
  should drop t05.
- The guard list should add i4, j1, j2, j3 (H1), i1 (`v[x.n] = poke(!v)`, the index walked after
  the value), the three `int.eq_then_write` lines, k4, k6, f1, f4, and the four
  `review-results-*` drop-body lines.

## Revisions required

1. Fix H1 first, as its own change: `fail` cases i4, j1, j2, j3, with the oracle as reference.
   It rejects programs a release accepted, so it needs the release-notes and Trig-note rule.
2. Drop the sentence 6 clause. Put the order rule in §6 as the paragraph in §1 above: calls and
   operators, read-in-place versus copied, a write view's read leaving a read loan. Make it say
   so in plain terms: it adds the operator rule, which only SPEC has today.
3. Replace `readsAsValue` in the liveness rule with that by-type split. The checker reads the
   type facts (`sema.copies`, shares-storage) and decides nothing again.
4. Add defers to the binding clause.
5. Restate (C) for `match` and `if … as` only, as CORE §3 already decides them. Move the `for`
   held base (t05) to its own row, with a recorded copy fact. Cover hidden statement temporaries
   (H11), or list them as not covered.
6. Land the oracle's §6 rule first, as its own PR. Treat a stale `ref-gap` line as an alarm.
7. Correct the gain and guard lists, and "nothing accepted today is rejected".
8. Make the walked set part of the rewound walk state (H2), and add g2 as a sanitizer test (H4).
