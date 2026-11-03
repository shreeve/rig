# Row 33D: a statement's loans end at their last use (CORE §6): draft 2, final pass

Rig - Swiss, 2026-11-01, against main ad5d9b043. Draft 1 (`draft.md`) went to three expert
reviews: CORE and soundness (`expert-core.md`), the compiler (`expert-compiler.md`), and
adversarial programs (`expert-adversary.md`, with every program and its output). This draft takes
their revisions. Where they disagreed, it states the choice and why. Decisions for the owner are
at the end.

## First: main is unsound today (its own hotfix, before 33D)

Two reviewers found this independently, and I reproduced it (`probes/draft/m1_ifbug.rig`; the reviewers' forms are in `probes/adv-m/`, the
late-read shapes in `probes/adv-h/`). `walkIf` walks a
condition as its own statement. Liveness then starts at the condition's position, so a use in the
then-branch, which comes earlier in the source but runs later, counts as already behind:

```rig
s = ?v[..]
print(s[0]) if grow(!v)          # main accepts; RIG_SANITIZE=1: use of freed memory
```

The same goes for `print(r.n if bump(!v) > 0 else 0)`, `n = r.n if ...`, `return r.n if ...`,
`print(r.n) if take(<v) > 0` (a move), and `print(w + 0 if poke(!a) > 0 else 0)` (prints 101, not
1). The oracle rejects every one (`DIFF prod=accept ref=reject C4`), but no case in the suite has
this shape. It has been there since at least dcf3c146d (2026-10-25). The fix: a binding is live
while a use in the enclosing statement, the whole one, is not yet walked. That is the same
mechanism 33D needs, so it lands first, as its own change. It rejects programs that main accepts,
so it needs release notes and a note to Trig.

There is a second, separate finding. On main, `f(b: r, a: bump(!v))` with a plain `r = ?u[0]`
emits Zig that fails to compile (North Star 1; expert-adversary `h1_nf_ok`). It is a row of its
own.

## What draft 1 got wrong

- **It missed emit's late reads.** `storage.isPureArg` calls a fixed local pure. Emit then reads
  it at the consumer, after later operands: keyword arguments out of order, a hoisted call, a
  hoisted array, and an assignment's value or indices. Examples: `f(b: r, a: bump(!v))` emits
  `f(bump(&v), r.*)`, and `xs[bump(!v)] = r`. Draft 1 would accept six such shapes, and each one
  reads freed memory. Statement-long loans hid this weak spot ("Evaluation order versus what is
  emitted"). (expert-compiler, expert-adversary)
- **Its read-point classifier was wrong.** `readsAsValue` is a type predicate. Where emit actually
  copies an operand is the recorded fact `sema.readsThrough` (typecheck's `readOf`), which the
  checker's `copiedOut` already reads. Emit copies a view of plain data at the operand
  (`rig.eql(r.*, bump(&a))`). With `readsAsValue`, half of the claimed `eq` gains stayed
  rejected. (expert-compiler, expert-adversary)
- **(C) was misdiagnosed.** `walkMatch` already clears its hidden `hold` var once an arm is
  chosen. What keeps `v` lent through the arms is the subject's `temps`, which are shrunk only for
  a lent subject with a root (ownership.zig:7022, 7154). The `for` half was unsound: a loop reads
  its source on every pass (CORE §3), and Zig captures the slice once (`for x in all(?v)` with a
  push in the body). (all three)
- **t05 is not a 33D gain.** A use in a `for` header counts as a use in the loop (`LoopCtx.start`
  includes the header). A rule that gains it must say that a `for` header runs once while a
  `while` condition runs on every pass. That is its own row.
- **The walked-use set was underspecified.** It must cover the whole statement, not only the
  innermost one, so that the bug above is fixed too. It must rewind with the checker's state, so
  that loop fixpoint rounds do not keep marks. A binding's own declaration leaf is not a use, and
  a `defer` or `errdefer` use counts at every exit.
- **A binding read by a consumer that discards the walk's value loses its loans.** Examples:
  `walkReadArgs`, `walkIndexOf`, `walkThenHeld`. A binding's read must put its loans into `temps`
  until the consumer finishes, as `holdMoved` does for `<x`.
- **"No new CORE rule" was wrong.** CORE states the call order (§6) but not the operator order,
  which only SPEC §7 has. The clause belongs in §6, not in sentence 6, which already says "not
  until the lend's line ends".
- **"Nothing accepted today is rejected"** is false once the hotfix lands. After the hotfix it
  holds for 33D.

## The rule: CORE §6, its evaluation-order paragraph, replaced

> A call evaluates its self and arguments left to right, then runs; an operator evaluates its
> operands left to right, then yields. Plain data read as a value (an operand, a field or element
> read, an argument to a parameter of a plain type) is copied where it stands, through a view
> too, and keeps nothing lent there. Whatever else an earlier argument or operand hands over (a
> view, which `print` and `String` arguments are; a value that shares storage its place owns; what
> a write view reaches) stays lent, to read, until the call returns or the operator yields, so a
> later one can't change it. A write lend of a method's self acts as a read loan until the call
> starts, so `!v.push(v.len)` works; a write lend in any other argument is a write loan at once,
> so `grow(!v, v.len)` is rejected. *(built)*

Sentence 6 is unchanged. With §6 it already gives the rest: a loan lasts until the last use, in
this order, of every view that carries it. That includes a binding's last use within its
statement, a defer's use at each exit, and a binding read inside a loop it was declared outside
of, which is used through the whole loop. A `match` or `if … as` reads its subject until an arm is
chosen (§3, already written), and after that only through what its bindings carry. A `for` reads
its source while the loop runs (§3, already written). This fits §10: it is one paragraph, it
follows the type (plain data, a view, or storage-sharing), and it has no exception list.

Expert-core's text put every view in place, including a `?Int` operand, so `r == bump(!a)` would
be rejected. I take expert-compiler's reading, which is decision 2. It is what is built for call
results today (`first(?v) + bump(!v)` and `add(first(?v), bump(!v))` are accepted and sanitizer
clean), emit copies there, and a binding of a type must act as a call result of that type does.

## Which pass records what

Only the ownership checker changes. Emit and storage are unchanged, and `tools/emit-diff` must
show identical output.
- **One rule at each node's end:** the `temps` taken since the node started shrink to what its
  value carries, plus what something else holds: a stored lend, a `drop`-body temporary's views,
  and `place_hold`, `held_read`, or a self's `reserved` until their call or operator finishes.
  `keepViewTemps` and `endWriteLends` fold into this rule. Under `-Dself-check`, it asserts that
  no entry below the node's start is touched.
- **A call or operator holds** its arguments' and operands' loans in `temps` until it finishes,
  except where `readsThrough` records a copy. A binding's read adds its loans there, as
  `holdMoved` does.
- **Emit's late reads:** a part that `storage.isPureArg` passes over in a hoisted call or array
  (`storage.hoistsArgs`), and the value and pure indices of an assignment (`storage.setOrder`), are
  used at the consumer. These are recorded facts. Narrowing `isPureArg` instead would change emit.
- **Walked uses:** `indexUses` records every use position of each symbol. A binding is live while
  one of its uses in the enclosing statement is not walked yet, or it has a later use (with
  `loopStartFrom` and `defer_used` as now). The set belongs to one walk of a statement and rewinds
  with `Point` and `State`.
- **Headers:** `walkMatch` and the `if … as` path shrink the subject's `temps` to what the held
  value and its bindings carry, for a made subject too. The held value stays used through every
  guard and every later arm's pattern until an arm is chosen. The `for` header is unchanged.
- **Owning temporaries with no `drop` body** are hidden vars, which are always live today. They
  get `holdsPastDrop`'s rule, about ten lines, so `mk(?v).len + grow(!v)` is accepted, as CORE
  allows.

## Programs

**Newly accepted:** b1, c1, c2, c3, write_result_whole, match_arm_writes, review-results-v07, all
8 `*.eq.write_view` and `*.eq.destructure_write` lines, d3, p74, and `mk(?v).len + grow(!v)`.
Under decision 2, the 3 `int.eq_then_write.*` lines are accepted too: they are now `ref-gap`
("compiler right") and would be deleted as decided. t05 is not gained.

**Stay rejected (guards, each a `fail` case):**
- the hotfix's seven forms;
- the six late-read shapes (h1_kw, h2_own, h4_set, h5_lam, h6_wint, h8_comp);
- a `for` over a view whose body writes the owner (`for x in all(?v)`, `r = ?v; for x in r`,
  `for x in ?v`);
- a match whose earlier arm's guard writes the owner (`guard1`);
- a `while` condition's view (`t05w`);
- a2 and the `arg_then_write` matrix (§6);
- b2 (`w == a`, `a: String`);
- d1 (a loop around the binding);
- a stored lend, a `drop`-body temporary's views, and a view of a temporary past its statement.

**Nothing accepted after the hotfix is rejected by 33D.** Loans only leave the live set earlier.
The self-checks (`headerTempLoan`, `verifyDecisions`) do not depend on statement-long loans
(expert-compiler §4). Expect churn in the error lists of existing `fail` cases.

## The oracle

It accepts every new gain already. It cannot see emit's order, so it is no guard for the
late-read class. Nor does it guard §6: it copies out a view argument, so it accepts a2 and the
`arg_then_write` matrix. During 33D, the `ref-gap` lines in `differences` serve as alarms: if one
goes stale (reported FIXED), that is a soundness failure, never a line to delete. The exception is
the 3 lines decision 2 settles. Teaching the oracle §6 is about 40–80 lines in lower.zig (around
2553 and 3840), and 26 `ref-gap` lines would leave the file. It needs the §6 text above first. The
reviewers split here: expert-core wants it first, as the guard, and expert-compiler wants it
dropped. The default is a tests-only row right after 33D (decision 5).

## Tests

About 25 cases in `test/rig/ownership-*.rig.test`. One accepting `test` for each gain, each run
under the sanitizer. Each forced late read uses a List grown past its capacity, so a wrong
acceptance crashes. One `fail` for each guard above. One case for each consumption form:
operator, call, method, field copy-out, `??`, `catch`, a branch, a postfix `if`. The hotfix
brings its own 7 cases.

## Size

The hotfix is about 30–60 lines (the whole-statement walked-use set) plus 7 cases. 33D is about
150–220 more lines in ownership.zig and about 25 cases, and its differences lines go: 14, or 17
with decision 2. Risk is moderate to high. It is concentrated in the late-read rule and in the
walked-use bookkeeping, and the guards above aim at both.

## Decisions for the owner (defaults first)

1. **Hotfix first.** Land the postfix-condition use-after-free fix as its own row, at the top of
   the queue: 7 `fail` cases, release notes, and a note to Trig. *Default: yes.* The broken-Zig
   keyword-argument emit (`h1_nf_ok`) becomes its own row after it.
2. **Operator operands.** Plain data read as an operand is copied where it stands, also through a
   view (`r == bump(!a)` with `r = ?a` and `a: Int` or `[3]Int` is accepted, as
   `first(?v) + bump(!v)` already is). The 3 `int.eq_then_write` lines become accepted.
   *Default: yes.* The alternative is SPEC's in-place reading for every view, under which
   `first(?v) + bump(!v)` should be rejected, and that program is accepted today.
3. **CORE text.** Replace §6's evaluation-order paragraph with the one above, and leave sentence
   6 alone. *Default: yes.*
4. **Scope.** (A) temporaries, (B) bindings, `match` and `if … as` subjects, and owning
   temporaries with no `drop` body go in 33D. The `for` header (t05) is its own row. *Default:
   yes.*
5. **Oracle §6.** Make it a tests-only row right after 33D. During 33D, a stale `ref-gap` line is
   an alarm and is never deleted. *Default: after.* The alternative is to land it before 33D.
6. **Emit unchanged.** The checker treats `isPureArg` parts as used at their consumer, so
   `tools/emit-diff` stays identical. *Default: yes.* The alternative is to narrow `isPureArg`,
   which changes emit.
