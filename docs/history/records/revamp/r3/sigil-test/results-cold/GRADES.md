# Cold sigil test: grades

Readers had no guide, only the programs. Sources: `key/questions.md`,
`key/outputs/`, `programs/{A,D}/`, `results-cold/cold-{A,D}{s,h,o}.md`.
Graded with no preference between the variants.

## Summary

| Reader | Variant | Model | First-guess accuracy (/11) | Question score (/52) | (a) errors | Lasting sigil misunderstandings | Rating |
|---|---|---|---|---|---|---|---|
| As | A | s | 10.5 (95%) | 52.0 | 0 | none | 7/10 |
| Ah | A | h | 10.5 (95%) * | 52.0 | 0 | none | 7/10 |
| Ao | A | o | 11 (100%) | 52.0 | 0 | none | 7/10 |
| Ds | D | s | 10.5 (95%) | 50.0 | 0 | none | 7/10 |
| Dh | D | h | 11 (100%) ** | 52.0 | 0 | none | 7/10 |
| Do | D | o | 11 (100%) | 52.0 | 0 | none | 7/10 |

\* Ah says the session context held AGENTS.md, which has the sigil table in
A's spelling, so its first guesses are not cold (see Caveats).
\** Dh's "first guesses" cite `Box[Node]?`, which first appears in p06, so
they were not written from p01–p03 alone.

**Variant means**

| | First-guess accuracy | Question score | (a) errors | Lasting misunderstandings | Rating |
|---|---|---|---|---|---|
| A | 10.67 / 11 (97.0%) | 52.00 / 52 | 0 | 0 | 7.0 |
| D | 10.83 / 11 (98.5%) | 51.33 / 52 | 0 | 0 | 7.0 |

If p05 Q3–Q4 (the known line-numbering trap) are left out, A scores
50/50 for every reader, and D scores 50, 50 and 49.5. Ds's one remaining half
point is p12 Q2, a judgment about whether a loop header counts as a
modification (tagged (d)).

## 1. First-contact accuracy

### Roles scored

There are 11 sigil roles in p01–p03. Both variants have the same roles.

| # | Role | A | D |
|---|---|---|---|
| 1 | read view type | `?Item` | `&Item` |
| 2 | read lend expression | `?items[0]`, `for it in ?items`, `report(?top)` | `&…` |
| 3 | write view type | `!Item` | `@Item` |
| 4 | write lend argument | `restock(!items[1], 5)`, `withdraw(!from, n)` | `@…` |
| 5 | write receiver, statement call | `!items.push(…)` | `@items.push(…)` |
| 6 | write call used as a value | `(!ws).next() as w` | `@ws.next() as w` |
| 7 | negation | `not x` | `!x`, `!(a > b)` |
| 8 | optional type | `Int?`, `Entry?` | same |
| 9 | read view of an optional | `?Entry?` | `&Entry?` |
| 10 | fallible type | `-> Int!`, `sub transfer(…)!` | same |
| 11 | propagate failure | `withdraw(…)!` | same |

The programs do not use `<x`, `+x`, `*T`, `@size`/`$size` or a postfix
`e?` until p05 or later, so these are not scored here.

Scoring: correct = 1, partly correct = 0.5, wrong = 0. A guess counts as
correct when the meaning the reader states, applied to that form, gives the
true meaning.

| Reader | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | Total |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| As | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | ½ | 1 | 1 | 10.5 |
| Ah | 1 | 1 | 1 | 1 | 1 | ½ | 1 | 1 | 1 | 1 | 1 | 10.5 |
| Ao | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 11 |
| Ds | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | ½ | 1 | 1 | 10.5 |
| Dh | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 11 |
| Do | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 11 |

The partial scores:
- **As, role 9:** lists `?Entry?` only as an example of "`T?` … = optional
  type". It never says the leading `?` makes a read view. This is
  incomplete, not a misread, and As's p02 answers are correct.
- **Ds, role 9:** the same pattern. `&Entry?` is listed only under
  "`?` after a type … optional type".
- **Ah, role 6:** gives no meaning for `(!ws)` at first contact. The form
  appears only under `as`. Ah later writes: "I did not guess that `(!x).m()`
  and `!x.m()` mean the same thing."

Ao, Ah and Dh state role 9 explicitly. Ao, for example, writes "I read it as
a read view of an `Entry?`."

### Wrong first guesses, quoted

**No reader made an outright wrong first guess about a sigil's meaning.**
The checks the brief asked for:

- A, `!x` as negation: no reader's first guesses say this. Ao hesitated
  once (below).
- A, `?x` as optional or nullable: none.
- A, `?T?` misread: none. As left it incomplete, as noted above.
- D, `@x` misread: none.
- D, `&x` misread: none.
- D, `!x` misread: none. All three read it as logical not.
- D, `$`: the prefix does not appear in p01–p03. Later, all three readers
  guessed that `$size` is a size in bytes, which is right.

Wrong first guesses about a usage rule or a keyword (not a sigil's meaning):
- Ah (A): "a read-only lend at that site, matching the `?` in the
  parameter". In fact a bare argument is lent to a read parameter implicitly.
  Ah calls this wrong in its revision.
- Do (D): "I first assumed it was always required" (the read `&` at a call
  site). It is the same rule.
- Dh (D): "I was unsure whether `fun` means pure". It does not. This is a
  keyword, not a sigil.
- Ds (D): "In `main`, crashing/unwrapping at the top level" for a postfix
  `!`. Ds later withdrew this; no question tests it.

### Momentary misreadings at first contact (from "Where I hesitated", p01–p03)

| Reader | Item |
|---|---|
| Ao (A) | p01:20 `!items.push(...)`: "I first wondered whether `!` negated the result of `push` (as in C `!f()`)" |
| Ao (A) | p03:16–17: "At first I mixed up postfix `!` (failure) with prefix `!` (write lend)" |
| Ah (A) | p03:17 `withdraw(!from, n)!`: "the last `!` first looked like a second write lend" |
| As (A) | trailing `!` on `sub transfer(...)!`: "initially thought `!` could mean 'mutating'" |
| As, Ah, Ao (A) | p01:31 `not it.qty > 3`: precedence. Read first as `(not it.qty) > 3` (As, Ah) or had to be settled (Ao) |
| Ah (A) | p03:33 `not bob.frozen or …`: precedence of `not` against `or` |
| As, Ao (A) | `(!ws).next()`: "reads oddly" (As); "The two spellings feel inconsistent" (Ao) |
| Ds (D) | p03:17: the trailing `!` "could be negation of the result, a write marker, or propagation" |
| Dh (D) | p03:17: the trailing `!` "I first thought it might be a negation" |
| Do (D) | p03:33: "I briefly checked whether `!bob.frozen` could be a write-lend like `@`; it is not" |
| Do (D) | p03:16 `sub transfer(...)!`: "first read as a typo" |
| Dh (D) | p02:29 `while @ws.next() as w`: "I first read the `@` as a sigil on the loop variable, not on the call" |

Every reader settled each of these before answering. None led to a wrong
answer.

## 2. Question accuracy

All four rejected programs (r01–r04) were answered correctly by every reader.

Rules, the same as the earlier round's (`results/GRADES.md`):
- A print format nothing defines is not penalized. One example is
  "`failed: insufficient` (possibly `Bank.insufficient`)", which all six
  readers wrote in some form.
- p05 Q3–Q4 slot rule: if the answer in the question's slot is the output of a
  different line, the reader gets 0.5 when the right output appears elsewhere
  in their answers, and 0 otherwise.

Every wrong or partial answer:

| Reader | Question | Answer given | Key | Score | Tag |
|---|---|---|---|---|---|
| Ds | p05 Q3 (line 35) | `49` (line 34's output) | `-1 -2` | 0.5 (`-1 -2` is in Q4's slot) | (d) |
| Ds | p05 Q4 (line 36) | `-1 -2` (line 35's output) | `700 none 0` | 0 (`700 none 0` appears nowhere) | (d) |
| Ds | p12 Q2 | 20, 21, 28, 29, 30 | 20, 21, 27, 28, 29, 30 | 0.5 | (d), borderline (b). Ds notes "27 sets up the write loan" but does not count it; Do also called the choice "a judgment call" |

There were no (a), (b) or (c) errors. The p05 misnumbering was 7 of 8 readers
in the earlier round; this time it was 1 of 6.

## 3. Revised meanings

Every reader ended with the right meaning for every sigil, including
the ones first seen later: `<x` (move, or a drop as a statement), `+x`
(clone), `*T` (shared refcounted), postfix `e?` (propagate none), and
`@size`/`$size` (a builtin, size in bytes). **No reader was left with a
lasting misunderstanding of a sigil.**

Points the readers noted that are not errors:
- In all six, the implicit read lend at a call (`value(items)` passed to a
  read-view parameter) was a surprise. All six got it right in the end.
- Dh writes "`x ?? y`: default when `x` is `none` or failed". The
  "or failed" part is unsupported, but `??` is not a scored sigil.
- Ah mentions "`-x` as 'drop now'". That spelling is not in these
  programs, so Ah took it from AGENTS.md. This is evidence of the
  contamination described under Caveats.

## 4. Ratings and symbol hesitations

All six readers gave **7/10**.

Overloads the readers named in "Overall":
- **A:** `!` and `?` "each carry two meanings depending on position", the
  prefix lend against the postfix propagate or optional (As, Ah, Ao: 3 of 3).
  The parenthesized `(!x).m()` against `!x.m()` (As, Ah, Ao: 3 of 3).
  Implicit read lends (As, Ah, Ao). `<x` as a bare drop (As, Ao).
- **D:** `!` carries "three meanings (not, fallible type, propagate
  failure)" (Ds, Do; Dh names the `?`/`!` suffix overload). The optional `&`
  at read call sites (Dh, Do). `<x` looks like a comparison (Dh, Do).
  `$size` was undefined (Dh). No D reader called `@v.m()` confusing.

Later hesitations about symbols, after p03:
- In both variants, `digit(s[0])?` and `due?` were first read as types or a
  ternary (Ah, Ao, Ds, Dh, Do).
- In both variants, `<base` or `<log` was first read as a comparison or a
  stray `<` (Ao, Ds, Dh, Do), and `+base` or `+log.lines` as unary plus
  (Ao, Ds, Dh, Do).
- In both variants, `*Config` was first read as a pointer or dereference
  (Ah, Ao, Do).
- In A, `!n.left if … else !n.right` (p06:8) took a second read (As, Ah, Ao),
  and Ah first read `if !slot as n` as "if not slot".
- In D, `@n.left if … else @n.right` took a second read (Ds, Dh, Do). No D
  reader read `@slot` as anything other than a write.

## 5. A against D at first contact

1. **Accuracy is tied, at the ceiling.** The first-guess means are 97.0% for A
   and 98.5% for D. Each half point comes from a reader leaving a form
   unexplained, not from a misread. There were no wrong sigil guesses and no
   (a) errors in either variant. With 3 readers per variant, the difference
   of 0.17 role is noise.
2. **Each variant's ambiguity sits in a different place, and both cost a
   pause on p03:17.**
   - In A, the prefix `!` (write) and the postfix `!` (propagate) were
     confused for a moment by all three readers. Once (Ao, p01:20), the
     prefix `!` was read as a C-style negation. All three readers also
     hesitated over `not` precedence in `not it.qty > 3`, and two of them
     over the parenthesized `(!ws).next()`.
   - In D, the prefix `!` (not) and the postfix `!` (propagate) were
     confused for a moment by all three readers. Once (Do, p03:33), the
     prefix `!` was checked as a possible write lend. No D reader hesitated
     over `@`, `&`, `@v.m()` or negation precedence, since D writes
     `!(a > b)`. One reader (Dh) first attached the `@` in `@ws.next()` to
     the wrong token.
3. **D's prefix sigils read as their meaning at once.** All three D readers
   read `&` as read and `@` as write with no hesitation. In A, `?x`/`!x` were
   also guessed correctly by all three, but two of them may have done so with
   help from AGENTS.md (see Caveats). By the readers' own counts, A has more
   first-contact friction points (precedence of `not`, the parenthesized
   receiver, and `!` on both sides of a name) than D (`!` on both sides of an
   expression).

## Caveats

- **There are 3 readers per variant, and every reader is an AI model.** No
  difference here reaches significance. Humans may react differently,
  especially to `!x` meaning write: a C or Rust programmer reads it as
  negation.
- **The test was probably not fully cold, and the contamination favors A.**
  The test directory sits inside the Rig repository. Ah and Dh both report
  that AGENTS.md was loaded into their context. That file's sigil table
  defines `?x`/`?T` as read and `!x`/`!T` as write, which is variant A's
  spelling. Ah says so directly ("the match may come from having seen it")
  and later cites `-x` as "drop now", which only the table contains. Dh says
  it did not use the table. As, Ao, Ds and Do say nothing about it, but they
  likely had the same context. So A's first-contact scores may be inflated.
  For D, the table could have pulled the other way: Do checked whether
  `!bob.frozen` "could be a write-lend".
- Dh's first guesses mention p06 content, so they were not strictly limited
  to p01–p03.
- A ceiling effect: 5 of 6 readers scored 52/52, so the questions do not
  separate the variants. The first-contact hesitations are the more useful
  signal.
