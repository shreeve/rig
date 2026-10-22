# Grades: clean no-guide test, variants A and D

Graded against `key/questions.md` and `key/outputs/`. Eight readers: four
models per variant. A-opus, D-fable and D-haiku were rerun with
`prompt2.txt`.

## Summary table

| Reader | Variant | Model | Prompt | First guesses | Questions (half credit) | Questions (strict) | (a) errors | Lasting misreadings | Rating |
|---|---|---|---|---|---|---|---|---|---|
| A-sonnet | A | sonnet | 1 | 10/10 | 52/52 | 52 | 0 | none | 7 |
| A-haiku | A | haiku | 1 | 10/10 | 51.5/52 | 51 | 0 | none | 6 |
| A-opus | A | opus | 2 | 10/10 | 51.5/52 | 51 | 0 | none | 6 |
| A-fable | A | fable | 1 | 10/10 | 51.5/52 | 51 | 0 | none | 6 |
| D-sonnet | D | sonnet | 1 | 10/10 | 51/52 | 50 | 0 | none | 7 |
| D-haiku | D | haiku | 2 | 10/10 | 51/52 | 50 | 0 | none | 6 |
| D-opus | D | opus | 1 | 10/10 | 52/52 | 52 | 0 | none | 7 |
| D-fable | D | fable | 2 | 10/10 | 51.5/52 | 51 | 0 | none | 7 |

**Means per variant**

| | First guesses | Questions (half credit) | Questions (strict) | (a) errors | Lasting misreadings | Rating (all) | Rating (prompt 1 only) |
|---|---|---|---|---|---|---|---|
| A | 100% | 51.63 | 51.25 | 0 | 0 | 6.25 | 6.33 (n=3) |
| D | 100% | 51.38 | 50.75 | 0 | 0 | 6.75 | 7.00 (n=2) |

"Half credit" gives 0.5 for an answer with the right substance and a wrong
or hedged detail. "Strict" counts only a full match with the key.

## 1. First-contact accuracy

### Sigil roles present in p01–p03

| # | Role | A spelling | D spelling |
|---|---|---|---|
| R1 | read view type | `?Item` | `&Item` |
| R2 | read lend | `?items[0]`, `for it in ?items`, `report(?top)` | `&items[0]`, `&items`, `&top` |
| R3 | write view type | `!Item`, `!Account` | `@Item`, `@Account` |
| R4 | write lend, including a statement method receiver | `!items.push(..)`, `restock(!items[1], 5)` | `@items.push(..)`, `restock(@items[1], 5)` |
| R5 | write call used as a value | `(!ws).next()` | `@ws.next()` |
| R6 | negation | `not` (keyword) | `!x`, `!(..)` |
| R7 | optional type | `Int?`, `Entry?` | same |
| R8 | read view of an optional | `?Entry?` | `&Entry?` |
| R9 | fallible type | `-> Int!`, `sub ..()!` | same |
| R10 | propagate failure | `withdraw(..)!`, `transfer(..)!` | same |

Builtins (`@size` / `$size`), `<x`, `+x`, `*T` and postfix `e?` do not
appear in p01–p03, so first contact does not test them.

### Per-reader scoring

Correct = 1, partly correct = 0.5, wrong = 0. "impl." means the reader did
not name that exact form, but its general rule covers it and nothing
contradicts it.

| Reader | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | R9 | R10 | Score |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A-sonnet | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 10/10 |
| A-haiku | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 10/10 |
| A-opus | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 10/10 |
| A-fable | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 10/10 |
| D-sonnet | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ impl. | ✓ | ✓ | 10/10 |
| D-haiku | ✓ | ✓ | ✓ | ✓ | ✓ impl. | ✓ | ✓ | ✓ impl. | ✓ | ✓ | 10/10 |
| D-opus | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 10/10 |
| D-fable | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 10/10 |

Notes on the cells:

- R6 in A is the keyword `not`. All four A readers named it as boolean
  negation and three stated its precedence, `not (a > b)`. It is not a sigil
  guess and gives A no real test of this role. Without R6, every reader
  still scores 9/9.
- R8: all four A readers and D-opus and D-fable named `?Entry?` /
  `&Entry?` explicitly and read it correctly. D-sonnet and D-haiku did not
  mention it.
- R5: D-haiku listed `while @ws.next() as w` only under `as`, and did not
  explain its `@`. Its general `@` rule covers it.
- Hedges that were not counted as errors:
  - A-haiku and A-sonnet both read R10 correctly. A-haiku added "Possibly
    it also unwraps", which is true. A-sonnet added "inside main ... it
    aborts the program", which is a fair reading.
  - D-haiku hedged on R3 and R4: "I'm unsure whether `@` is just a marker
    at the call site or a real operator." The meaning it gave was right.

### Wrong first guesses, quoted

**There are none, in either variant.** No reader's "First guesses" section
read `!x` as negation, `?x` as optional, `?T?` wrongly, `(!v).m()` wrongly
(A), or `@x`, `&x` or `!x` wrongly (D).

The only wrong first guesses were about keywords, not sigils:

- D-haiku: "`sub`: a procedure that may mutate its `@` arguments, as
  opposed to `fun`."
- D-opus: "`fun` is a function that returns a value, probably pure."
- D-fable, for `fun`: "probably pure or at least value-producing."

All three corrected these by the end. The same spellings appear in A, so
the guesses are not caused by the variant.

### Transient misreads, from the hesitation sections

The "First guesses" were all correct. But the hesitation sections show
moments where a reader briefly took one meaning before settling on
another. Under prompt 1 these are "what you first thought". Under prompt 2
they are "readings it allowed", so they are flagged ambiguities, not
misreads. Shared symbols that are spelled the same in both variants (`+`,
`<`, `*`, postfix `e?`, `??`) are left out.

| Reader | Prompt | Transient misreads or ambiguities of a variant-specific symbol |
|---|---|---|
| A-sonnet | 1 | `?Item`: "could not tell whether `?Item` meant 'optional Item' or a borrow." `?items[0]`: "first read it as a ternary-like or optional construct." `(!ws).next()`: "I first took `!ws` as boolean negation." Trailing `!` on p03 l.17: "had to separate the two meanings (lend versus propagate)." |
| A-haiku | 1 | p05 l.25 `!pos`: "I first read `!pos` as negation." Trailing `!` on p03 l.17: "considered whether it negates or unwraps." |
| A-opus | 2 | `!items.push(x)`: "whether the `!` applies to `items` or to the whole call result." `?Entry?` and `!Box[Node]?`: "Easy to misread." |
| A-fable | 1 | `(!ws).next()`: "wondered why this has parentheses when `!items.push` does not". Overall: "The inconsistency between `!x.m()` and `(!x).m()` cost a re-read." |
| D-sonnet | 1 | `@from`: "wondered whether `@` meant 're-borrow' or 'address-of'." Trailing `!` on p03 l.17: "briefly considered it as negation." `match @s`: "I first thought `@` here meant a pattern." |
| D-haiku | 2 | Trailing `!` on p03 l.17: "could be 'not' or 'propagate'." `job = @q.next()`: "looks like a read, but it removes an element." |
| D-opus | 1 | `$size`: "an unfamiliar sigil", guessed correctly. Nothing on `&`, `@` or `!`. |
| D-fable | 2 | None on `&`, `@`, `!` or `$`. It noted `if &note as n` and `match @s` as new forms and read them correctly. |

Counted the same way (prompt-1 readers only, since the prompt-2 wording
asks for something different):

- A: 7 transient misreads among 3 readers. Four involve prefix `!` or
  `?` (two of them read `!` as negation), two are the trailing `!`, and
  one is about `(!x).m()` versus `!x.m()`.
- D: 4 among 2 readers. One is the trailing `!` as negation, one is `@` as
  address-of, one is `@` as a pattern, and one is `$size` being
  unfamiliar.

## 2. Question accuracy

Every lost point is tagged (d). No reader lost a point to a sigil misread
(a), an ownership concept (b) or a tracing slip (c).

| Reader | p03 Q2 | p12 Q2 | Other | Total |
|---|---|---|---|---|
| A-sonnet | full (`failed: Bank.insufficient`) | full | — | 52 |
| A-haiku | 0.5 (d) | full | — | 51.5 |
| A-opus | 0.5 (d) | full | — | 51.5 |
| A-fable | 0.5 (d) | full | — | 51.5 |
| D-sonnet | 0.5 (d) | 0.5 (d) | — | 51 |
| D-haiku | 0.5 (d) | 0.5 (d) | — | 51 |
| D-opus | full (`failed: Bank.insufficient`) | full | — | 52 |
| D-fable | 0.5 (d) | full | — | 51.5 |

**p03 Q2, (d).** The key's output is `failed: Bank.insufficient`. Six
readers gave `failed: insufficient`, mostly naming `Bank.insufficient` as
the alternative, and all got the behavior right: there is a failure and no
balance changes. The code never shows how an error value prints, so the
exact text cannot be worked out from it. This counts as unknowable from
the material, not as a reading error.

**p12 Q2, (d).** The key's lines are 20, 21, 27, 28, 29, 30.

- D-sonnet answered 20, 21, 28, 30 and added "Lines 27 and 29 are where
  write access is taken".
- D-haiku answered 20, 21, 28, 30 and said: "Lines 27 and 29 hand out
  mutable access, but the actual writes happen on lines 28 and 30 ...
  'may be modified' could be read to include the loop and binding lines."

The reader-facing definition is "the value's contents may change on that
line ... through a function or method it is handed to for writing". Under
that definition, excluding a line that only creates a write view is a
defensible reading. The key also excludes the read-view line 24 in p01 Q3,
which is the mirror case. Both D readers read `@` correctly and named
what lines 27 and 29 do. All four A readers included 27 and 29. This
difference may reflect how `!players` and `@players` look. With n=2 and
the question's own ambiguity, it is weak evidence.

**p05 Q3 and Q4, (d), no deduction.** The program is misnumbered by one
line. Line 34 prints `-1 -2` and line 35 prints `700 none 0`, and there is
no line 36. All eight readers gave the key's intended answers, `-1 -2` and
`700 none 0`, so nobody lost a point.

The rejected programs r01–r04 were all correct for all eight readers. The
common wrong answers listed in the key (r01 l.16, r03 l.15, r04 l.12/13)
did not occur. Several readers said r04 "could be reported at line 15" but
still chose 14.

## 3. Revised meanings

None of the eight readers kept a misunderstanding of a sigil to the end.
Every final glossary has the right meaning for read lend and view, write
lend and view, negation, `T?`, `e?`, `T!`, `e!`, `<x`, `+x`, `*T` and the
size builtin.

Points that were right but stated loosely:

- A-haiku and D-haiku describe `<x` as "release or move". This is right:
  it means drop as a statement and move as an argument.
- A-fable describes the `!` placement rule as "statement position versus
  expression position". This describes the `(!x).m()` spelling
  accurately.

The keyword guesses about `fun` and `sub` (D-haiku, D-opus, D-fable) were
corrected in the revised meanings.

## 4. Ratings and symbol-related hesitations

| Reader | Rating | Symbol complaints in "Overall" |
|---|---|---|
| A-sonnet | 7 | `?` and `!` "each have several meanings depending on position ... the main source of confusion"; `not a > b` precedence; `+`/`<` |
| A-haiku | 6 | `?`, `!`, `+` "each appear as both prefix and postfix, and `!` also means 'not' in `!=`"; `*`/`+`/`<` |
| A-opus | 6 | "`?` and `!` are each overloaded four ways, and the meaning flips depending on whether the symbol is before or after a name"; `*`/`+`/`<` |
| A-fable | 6 | `!` write borrow before, propagation after; `?` three roles; "inconsistency between `!x.m()` and `(!x).m()`"; `<` collides with less-than |
| D-sonnet | 7 | "`!` is negation, 'can fail' and 'propagate'. `?` is an optional type and an early-return operator"; `+`/`<` |
| D-haiku | 6 | "`!`, `?` and `@` each mean several things depending on position"; field assignments need no `@`; `<`/`+`/`*` |
| D-opus | 7 | "`!` has three roles (not, failure type, propagate) and `?` has two"; implicit `&` at some call sites; `*`/`+`/`<` |
| D-fable | 7 | `*`/`+`/`<` unguessable; "`?` suffix doing double duty"; praises "`&` for read, `@` for write" |

Both variants draw an overloading complaint. In A, the complaint is that
`?` and `!` each serve both a lend role and a postfix role. In D, the
complaint is that `!` is both negation and the failure suffix. In both
variants, every reader named `+`, `<` and `*` as the hardest symbols to
read cold. Those are spelled the same in A and D.

## 5. A versus D at first contact

- **Accuracy is tied at the ceiling.** Both variants score 40/40 on first
  guesses (100%). On this measure, cold readers decoded every lend,
  view, negation and failure sigil correctly in both spellings, so the
  test cannot separate A from D.
- **A's cost shows up as transient confusion, not as errors.** Among the
  prompt-1 readers, two of three A readers briefly read a prefix `!` as
  negation (A-sonnet on `(!ws)`, A-haiku on `!pos`). A-sonnet also
  briefly took `?Item` as optional and `?items[0]` as an optional or
  ternary. These are exactly the A risks the test was set up to catch.
  Each was resolved within the same program, before the first-guess
  section was written.
- **`(!v).m()` versus `!v.m()` is A's most specific friction.** A-fable
  named it a re-read cost and A-opus flagged the scope of `!` on a
  receiver. No D reader raised a corresponding issue with `@v.m()`.
- **D's friction is smaller and different.** The trailing `!` read as
  negation (D-sonnet, briefly; D-haiku, as an ambiguity), `@` as
  address-of or as a pattern (D-sonnet), and `@q.next()` looking like a
  read (D-haiku). `$size` drew one "unfamiliar sigil" remark and was read
  correctly.
- **Ratings favor D slightly.** The means are 6.75 for D and 6.25 for A,
  or 7.0 and 6.33 on prompt-1 readers only. Within each model the
  difference is 0 or +1 for D. Question scores favor A slightly (51.63
  and 51.38), but all of that difference comes from (d) items. None of it
  comes from reading a sigil.

## Caveats

- **Small n.** There are four readers per variant, one per model, and the
  pairing by model is the only control. A one-point rating difference
  within a model is within run-to-run noise.
- **All readers are AI models.** They are strong at Rust, Zig and Swift
  idioms, which both variants borrow from (`&` for read, `!` for
  propagate, `T?` for optional). Human first contact may differ,
  especially for `!x` as a write lend against long C habit.
- **The prompt changed for three reruns.** A-opus, D-haiku and D-fable
  used `prompt2.txt`, which asks for "readings it allowed" instead of
  "what you first thought". Their hesitation sections therefore list
  ambiguities, not admitted misreads, and are not directly comparable
  with the prompt-1 readers. The rerun split is uneven (one A, two D), so
  the transient-misread counts above use prompt-1 readers only: 3 A and
  2 D.
- **Ceiling effects.** First guesses are 100% and question scores are
  51–52 out of 52 everywhere, so neither measure discriminates. The
  remaining signal is in the hesitations and ratings, which are
  self-reported.
- **Answer-key issues.** Two key issues cost points, all tagged (d):
  p03 Q2 depends on an error-print format the code never shows, and p12
  Q2's key counts lines that only create a write view. The p05 Q3/Q4
  misnumbering cost nobody a point.
- **Negation is not a like-for-like role.** In A, negation is the keyword
  `not`, which no reader would misread. In D it is the sigil `!`. The R6
  column therefore tests D but not A. A's matching risk, a prefix `!`
  read as negation, shows up under R4 and R5 instead.
