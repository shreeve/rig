# Sigil usability test: grades

Graded blind to any preference among the variants. Sources: `key/questions.md`,
`key/outputs/`, `key/writing-solutions.md`, `results/read-*.md`,
`results/write-*/`.

Before grading I regenerated B, C and D from `programs/A` with `translate.py`.
The output was identical to `programs/{B,C,D}`, so the variants differ only
in the intended spellings.

## Summary table

| Variant | Reader 1 | Reader 2 | Reading mean (/52) | (a) sigil misreads | Mean reader rating | Writing sigil errors | Writing non-sigil errors | Writer rating |
|---|---|---|---|---|---|---|---|---|
| A (`?x` `!x` `(!v).pop()` `not` `@size`) | A1 51.0 | A2 52.0 | **51.5** | 0 | 7.5 (8, 7) | 3 | 5 | 4 |
| B (`&x` `!x` `(!v).pop()` `not` `@size`) | B1 52.0 | B2 51.0 | **51.5** | 0 | 7.5 (7, 8) | 5 | 6 | 5 |
| C (`&x` `@x` `@v.pop()` `not` `$size`) | C1 51.5 | C2 51.5 | **51.5** | 0 | 7.5 (7, 8) | 3 | 3 | 5 |
| D (`&x` `@x` `@v.pop()` `!x` `$size`) | D1 51.0 | D2 51.0 | **51.0** | 0 | 8.0 (8, 8) | 3 | 3 | 5 |

The only points lost in reading came from p05 Q3 and Q4 (see below). Leave
out those two questions and **all eight readers score 50/50**.

Writing sigil errors that leave out the two receiver errors every writer made
(a gap in the guide, see below): A 1, B 3, C 1, D 1.

## Character totals (`lengths.txt`, p01–p12, `wc -c`)

| A | B | C | D |
|---|---|---|---|
| 8909 | 8909 | 8895 (−14, −0.16%) | 8866 (−43, −0.48%) |

C saves a character for each `(!v).m()` written as `@v.m()`, and for each
`@size` written as `$size`. D also saves 3 for each `not x` written as `!x`,
but adds 2 for each operand it has to parenthesize: `!(it.qty > 3)`,
`!(e.word == "the")` and r01's `!(acct.balance > 50)`.

## 1. Reading

### Scoring criteria

- 1 point for an answer that matches the key or an accepted alternative.
- Print formats the guide does not define (how an error value, `none` or a
  Vec prints) are not penalized when the substance is right. An example is
  "`failed: insufficient` (possibly `Bank.insufficient`)", which A1, A2, B1,
  C1, C2 and D1 wrote. B2 and D2 gave `Bank.insufficient`. A strict score
  would treat every reader about the same, so it would not change the
  ranking.
- Extra correct detail is not penalized.
- **Line-mapping rule (p05 Q3–Q4):** the answer written in the question's own
  slot is what counts.
  - The slot is right, or the reader explicitly corrected it: 1.
  - The slot holds the output of a different line, but the right output for
    the asked line appears elsewhere in that program's answers: 0.5.
  - Otherwise: 0.

### Every wrong or partial answer

| Reader | Q | Answer given | Key | Score | Cause |
|---|---|---|---|---|---|
| A1 | p05 Q3 (line 35) | `49` (that is line 34) | `-1 -2` | 0.5 (`-1 -2` given in Q4's slot) | (c) |
| A1 | p05 Q4 (line 36) | `-1 -2` | `700 none 0` | 0.5 (`700 none 0` given as "line 36, not asked") | (c) |
| B2 | p05 Q3 | `49` | `-1 -2` | 0.5 | (c) |
| B2 | p05 Q4 | `-1 -2` | `700 none 0` | 0.5 (given "for completeness") | (c) |
| C1 | p05 Q3 | `49` | `-1 -2` | 0.5 (Q4's slot says "Line 35 prints `-1 -2`") | (c) |
| C2 | p05 Q3 | `49` | `-1 -2` | 0.5 (a following line says "Line 35 prints `-1 -2`") | (c) |
| D1 | p05 Q3 | `49` | `-1 -2` | 0.5 | (c) |
| D1 | p05 Q4 | `-1 -2` | `700 none 0` | 0.5 (given in a note) | (c) |
| D2 | p05 Q3 | `49` | `-1 -2` | 0.5 | (c) |
| D2 | p05 Q4 | `-1 -2` | `700 none 0` | 0.5 (given as "line 36, not asked") | (c) |

A2 made the same shift and then explicitly corrected both answers, so A2
scores 1 on each. B1 made no error.

**This error is systematic.** 7 of the 8 readers, spread over all four
variants, first answered p05's "line 35" and "line 36" with the outputs of
lines 34 and 35. The questions skip the first `print` in `main` (line 34),
and readers seem to have assumed the questions follow print order. I tagged
it (c), a tracing slip, but it is better read as a trap in the question
design. Nothing about it depends on the variant.

### (a) sigil-misread errors

**None, in any variant.** Every reader answered the questions that probe a
symbol directly:

- p03 Q3: what the trailing `!` on line 17 does;
- p10 Q2: what the trailing `!` on line 13 does;
- p05 Q1, p04 Q2 and p12 Q3: the negations;
- p02 Q1 and p06 Q2: read lend against write lend;
- p01 Q3, p06 Q1 and p12 Q2: which lines modify a value;
- r01–r04.

D's `!x` negation next to a postfix `e!` caused no misread. B's `&` read next
to `!` write caused none either.

No (b) ownership-concept errors and no (d) errors beyond the p05 item above.

### "Where I hesitated": items about symbols

**A1 (rating 8/10)**
- How `not` binds against `or` (p03:33).
- How `?` binds against `*` in `digit(s[0])? * 100` (p05:31).
- `insert(!n.left if key < n.key else !n.right, key)` (p06:8).
- Bare `root` next to `!keys` (p06:35, 37).
- `(!stack).pop() as x` (p10:8): "the guide covered this form".
- `not` combined with a trailing `if` (p11:27).

**A2 (rating 7/10)**
- `not` against `or` (p03:33), and `not it.qty > 3` (p01:31).
- `?` against `*` (p05:31).
- `!n.left if … else !n.right` (p06:8).
- p11:15 `due? - today`: "I first thought `?` was a lend".
- Overall: the hard part was the same symbol in different positions, with
  `?` as read lend, optional type and pass-none-up, and `!` as write lend and
  pass-failure-up. The parenthesized `(!v).pop()` form was also hard.

**B1 (rating 7/10)**
- `not` against `or` (p03:33).
- `not it.qty > 3` "reads like `(not it.qty) > 3` at first" (p01:31, p02:33).
- `?` in `digit(s[0])? * 100`.
- `<base` alone on a line read first as a move with no target.
- `!n.left if … else !n.right`.
- Bare argument against a `&` parameter, and `for t in tasks` without `&`.
- `(!x).method()` "is easy to confuse with `!x.method()`" (p04:15, p10:8).
- `match !s` binding.
- Overall: `!` serves as write lend, fallible type and propagation, and `?`
  as optional and propagation; `(!v).pop()`.

**B2 (rating 8/10)**
- `digit(s[0])?` first read as part of a type.
- p06:8 `!n.left if … else !n.right` "parsed as a conditional expression of
  write lends, not a negation". The reader checked whether this `!` was a
  negation.
- `not` against `or`, and `not it.qty > 3`.
- `match !s` binding.
- Overall: `!` serves as write lend, fallible type and propagation, and `?` is
  overloaded; `(!v).pop()` "took an extra look".

**C1 (rating 7/10)**
- "`@` vs `&` at first: I had to keep remembering `@` is write and `&` is read
  (in many languages `&` is the generic reference)."
- `<name` alone means drop, but means move elsewhere.
- `due? - today`.
- `not a == b`: "first instinct would be `(not a) == b`".
- `target = @players[...]` as a lasting write view.

**C2 (rating 8/10)**
- p03:17 `withdraw(@from, n)!`: "'write' and 'failure' are both nearby".
- `not` against `or`.
- `<x` drop against move.
- `@n.left if … else @n.right`.
- `match @s` binding.
- `?` in `digit(s[0])?`.

**D1 (rating 8/10)**
- "`!` in both negation (`!x`) and postfix failure (`e!`): `transfer(...)!`
  and `if !in_stock(it)` are distinguished only by position."
- `@` both as a write view argument and on a write call (`@items[1]` against
  `@items.push`): "Fine after the guide".
- `?` as optional type, as pass-none-up, and in `??`.
- `catch -1`: whether it parsed as a subtraction.
- `@` in both branches of p06:8.

**D2 (rating 8/10)**
- How `?` binds in `digit(s[0])? * 100`.
- `@` in both branches of p06:8.
- Bare `root` next to `@keys`.
- `@` against `&` in patterns: whether `r` in `match @s` is a copy or an
  alias.
- "the dense `?`/`!`/`??` suffix operators".

### Symbol-hesitation themes by variant

- **A:**
  - `?` means three things (read lend, optional type, pass none up); one
    reader took a postfix `?` for a lend at first.
  - `!` means write and also propagation.
  - `(!v).pop()` was noted by one reader.
  - Both readers hesitated over how `not` binds.
- **B:**
  - `!` means three things (write lend, fallible type, propagation), and both
    readers raised it.
  - Both raised `(!v).pop()` against `!v.pop()`; one called them "easy to
    confuse".
  - One reader checked whether a prefix `!` was a negation.
  - Both readers hesitated over how `not` binds.
- **C:**
  - One reader had to remember the `@`=write, `&`=read mapping against prior
    habits from other languages.
  - One noted a write `@` next to a failure `!` on the same call.
  - Both readers hesitated over how `not` binds.
  - No one raised the write-call form `@v.pop()`.
- **D:**
  - One reader named the prefix-negation `!` against the postfix-failure `!`
    collision, but resolved it by position with no misread.
  - Both found the suffix operators dense.
  - **Neither D reader hesitated over negation precedence, against 6 of 6
    readers in A, B and C.** This is partly a confound: the translator wrote
    D's comparison negations with explicit parentheses (`!(it.qty > 3)`), so
    the question A, B and C readers faced does not arise in D.

## 2. Writing

### Method

I compiled A's solutions with `bin/rig run` under `RIG_SANITIZE=1`. I
translated B, C and D's solutions by hand into A's spellings, changing only
the sigils:

- `&x` → `?x` (B, C, D);
- `@x` → `!x`, and `@v.pop()` → `(!v).pop()` (C, D);
- `!c.is_empty()` → `not c.is_empty()` (D).

Each translation was compiled the same way. No translation needed any change
other than a sigil.

I made two more passes to separate the kinds of error:

- **Pass 2:** non-sigil errors fixed, sigil errors kept. This exposed sigil
  errors that the first errors had masked.
- **Pass 3:** every counted sigil error fixed as well. In this pass all 24
  programs compiled, printed the expected output, and ran sanitizer-clean. So
  the counts below are complete: no other error remains.

A sigil the compiler accepts and the guide supports is not counted as an
error even when the key omits it. Examples: `!tags.push(+s)` (an explicit
clone), `for s in ?extra`, and A's `b = ?first(shelf)`.

### Compile results (first pass, as written; B, C and D translated to A)

| Task | A | B | C | D |
|---|---|---|---|---|
| w1 | fail: `.len()` | fail: `.len()`; pass 2: bare `extra` to by-value param | fail: `.len()` | fail: `.len()` |
| w2 | **runs** `Dune 412` | fail: view of by-value param `books`; bare `shelf` | **runs** | **runs** |
| w3 | fail: `drop(self)` | fail: `drop()` with no receiver; bare `host` | fail: `drop(self)` | fail: `c: <Conn` (parse); pass 2: `drop()` |
| w4 | **runs** | **runs** | fail: `!b[0] = 10` (from `@b[0] = 10`) | **runs** |
| w5 | fail: `v.is_empty()`, `.len()` | fail: `v.is_empty()`, `.len()` | fail: `.len()` | fail: `.len()` |
| w6 | fail: `is_empty(self)`, `.len()`; pass 2: bare `Cart` arg to by-value `c: Cart` | fail: no receiver, `.len()`; pass 2: by-value `c: Cart` | fail: `is_empty(self)`, `.len()` | fail: `is_empty(self)`, `.len()` |
| Ran as written | 2/6 | 1/6 | 1/6 | 2/6 |
| Ran after non-sigil fixes | 4/6 | 2/6 | 3/6 | 4/6 |

### Every writing sigil error

**A (3)**
1. w3 line 4 `drop(self)`: the receiver is missing `!`; the key is
   `drop(!self)`.
2. w6 line 4 `fun is_empty(self)`: the receiver is missing `?`; the key is
   `(?self)`.
3. w6 line 7 `sub checkout(c: Cart)`: the parameter type is missing `?`.
   Without it, `c` is taken by value and the bare calls on lines 15 and 17
   are rejected.

**B (5)**
1. w1 line 1 `extra: Vec[String]`: missing `&`. The parameter becomes by
   value, so the bare call on line 11 is rejected.
2. w2 line 5 `books: Vec[Book]`: missing `&`. The function cannot return a
   view of a by-value parameter.
3. w3 line 4 `drop()`: the `!self` receiver is missing entirely.
4. w6 line 4 `fun is_empty()`: the `&self` receiver is missing entirely.
5. w6 line 7 `sub checkout(c: Cart)`: missing `&`.

The writer's notes give the reason for 1 and 2: "whether `books` param needs
`&`; chose bare (reads)". They carried the call-site rule (a bare argument is
read) over to parameter types.

**C (3)**
1. w3 line 4 `drop(self)`: missing `@`.
2. w4 line 7 `@b[0] = 10`: an extra `@` on an element assignment. Translated,
   it is a parse error. The writer flagged it as a guess: "maybe plain
   `b[0] = 10`".
3. w6 line 4 `fun is_empty(self)`: missing `&`.

**D (3)**
1. w3 line 4 `drop()`: the `@self` receiver is missing entirely.
2. w3 line 7 `sub finish(c: <Conn)`: an extra `<` on a type. It is a parse
   error, and `<` is spelled the same in every variant.
3. w6 line 4 `fun is_empty(self)`: missing `&`.

**Errors on the forms the variants actually change:**

- **Write call used as a value:** 4/4 correct.
  - A and B wrote `(!v).pop()`; C and D wrote `@v.pop()`.
  - A and B used it as `x = (!v).pop() ?? 0` inside `while not
    v.is_empty()`. That loop leans on a method Vec does not have.
  - C and D wrote the key's idiom `while @v.pop() as x` directly.
- **Negation:** 4/4 correct. D wrote `if !c.is_empty()`; the others wrote
  `not`.
- **Write lends at call sites and on receivers of mutating calls:** no errors
  in any variant.
- **Read sigil on parameter types:**
  - A: 1 miss out of 3 places.
  - B: 2 misses out of 3, plus 1 more in w6.
  - C and D: 0 misses.

  B's `&` is spelled the same as C's and D's, so the misses point to this
  writer rather than to `&`.
- **Extra write sigil:** C only (`@b[0] = 10`).

**Receiver errors common to all four writers:** each writer missed both
`drop`'s receiver and `is_empty`'s receiver, 8 of the 14 sigil errors in
total. None of the cheatsheets shows a `self` receiver or a `drop` body. These
errors measure that gap in the guide, not the spellings.

### Non-sigil errors

Each distinct mistake is counted once per solution.

| | w1 | w2 | w3 | w4 | w5 | w6 | Total |
|---|---|---|---|---|---|---|---|
| A | `.len()` | | | | `v.is_empty()`, `.len()` | `items.is_empty()`, `.len()` | 5 |
| B | `.len()` | | bare `host` | | `v.is_empty()`, `.len()` | `items.is_empty()`, `.len()` | 6 |
| C | `.len()` | | | | `.len()` | `.len()` | 3 |
| D | `.len()` | | | | `.len()` | `.len()` | 3 |

Every writer wrote `.len()` (it is a field) and `Vec[T]()`. The guide shows
neither.

### Writers' "unsure" points and ratings

- **A (4/10):**
  - The guide never shows Vec creation, push/len/index, or parameter and
    return types.
  - Whether the caller needs `?` on `?first(shelf)`.
  - The syntax of `drop(self)`.
  - `pop` returning `Int?`.
  - A bare `self` meaning read.
  - Whether block headers take colons.
- **B (5/10):**
  - Cloning with `+s`.
  - Whether a read parameter needs `&` ("chose bare (reads)").
  - `-> &Book`.
  - `drop()` syntax and bare fields.
  - The method syntax for `self`.
- **C (5/10):**
  - Vec construction, struct construction, and method names.
  - Whether a read parameter takes `&` or a bare type.
  - `-> &Book`, and whether the caller writes `b = &first(...)`.
  - The `drop(self)` and receiver syntax.
  - "`@b[0] = 10` … maybe plain `b[0] = 10`".
  - The form of `@cart.items.push`.
- **D (5/10):**
  - Vec construction and method names.
  - Parameter type syntax, including "`<Conn` … guide shows only `<x` on
    values".
  - `-> &Book`.
  - `drop()` syntax and the unannotated `self`.
  - `b[0] = 10` as a write.

All four ratings concern the guide's missing basic syntax, not the sigils.

## 3. Integrity

- **No contamination found.** I searched every reader and writer file for
  another variant's spellings: prefix `?` in B, C and D; prefix `!` as a lend
  in C and D; `not` in D; `@` or `&` lends in A; `$` against `@` builtins.
  - Every match used the participant's own variant correctly. For example, B
    readers write `(!cart.items).pop()`, C and D readers write
    `@cart.items.pop()`, and D2 writes `!q.is_empty()`.
  - No writer used a spelling from another variant.
- No participant claimed knowledge the guide does not give, beyond print
  formats (`none`, `[20, …]`, `Bank.insufficient`), and they flagged those
  as guesses.
- **The participants are almost certainly not independent.** The eight
  reader files share one structure, the same guesses, and nearly the same
  hesitation lists (`?? return`, p06:8, p05:31). The four writers made the
  same choices too: `Vec[T]()`, `.len()`, `+s`, and an unannotated `self`.
  They look like instances of the same model, so differences between
  variants are within-model noise, not population effects.

## 4. Caveats

- **Sample size:** 2 readers and 1 writer per variant, so 1 writer per cell.
  No difference in this table is statistically meaningful.
- **Ceiling effect:**
  - Every reader scored 50/50 on every question except p05 Q3–Q4.
  - The reading test cannot separate the variants, and no symbol caused a
    misread under any spelling.
  - Only two questions (p03 Q3, p10 Q2) ask directly what a symbol means.
- **p05 Q3–Q4 trap:** this accounts for all lost reading points, and it is
  independent of the variant.
- **D's negation confound:** D's programs parenthesize negated comparisons.
  This removes the `not`-precedence question that every A, B and C reader
  raised, so D's lower negation hesitation is partly the test material, not
  the spelling.
- **The writing guide has gaps:**
  - Receivers, `drop` bodies, parameter types, and the Vec API are not shown.
  - These gaps cause most writing errors (8 of 14 sigil errors, and all the
    non-sigil errors), equally in every variant.
  - Writers' ratings (4–5) score the guide, not the sigils.
- **Writer variance dominates:** B's extra errors (bare read parameter types)
  appear with a `&` that C and D used without error.
- **Only A can be compiled directly:** B, C and D were compiled after a
  hand translation. The translation was mechanical and caused no failures.
- **Length differences are small:** at most 0.48% (D against A/B).
