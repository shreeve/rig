# Panel round 3: `matches` (2026-11-02)

## Where rounds 1-2 landed (see summary.md, summary2.md and your own round-2 file)
The owner prefers the word `matches` to `is` (it keeps the word "match"). Current shape:
- `x matches P` is an operator giving a Bool; usable in `if`/`while` conditions (where it may bind
  names), in `and`/`or`, in assignments, and inside closures (no bindings there).
- One-arm form: `if <entry.state matches .ready(rendered?)` then the body; the full form stays
  `match <entry.state` with arms `.ready(rendered?) => ...` and `_ => pass`.
- Patterns are match's own (SYNTAX.md §12), plus nested `name?` and `none` (round 2).
- Alternatives use match's comma (`0, 1 =>`), and an alternative list binds no names.
- `as` keeps only naming an optional (`if o as x`).

## The owner's new questions
He thinks we're onto something excellent. He asks:
1. Inside a call, `.filter(|e| e.value.state matches .ready, .start, .frozen)` reads the commas as
   filter's arguments. Options he floated:
   (a) parens around the whole test: `.filter(|e| (e.value.state matches .ready, .start, .frozen))`
   (b) a call-like form: `.filter(|e| e.value.state matches(.ready, .start, .frozen))`
   Others possible: (c) parens around the list only `matches (.ready, .start, .frozen)`;
   (d) `or` between alternatives; (e) `|` between alternatives (as in Rust/OCaml patterns);
   (f) no alternatives in `matches` at all (write `matches .ready or ... matches .start`).
   Note Rig's rule: after a NAME, `[]` is compile time and `()` is a run-time call; `matches(...)`
   would look like calling a function named `matches`.
2. How useful are several alternatives anyway? Do we need them? (Ground it: count real cases in
   Trig, `~/Data/Code/trig/src`, e.g. one-real-arm matches listing several variants, and
   chains of `==` on enum values or `or` of tests.)
3. Do we need binding patterns like `.ready(r)` in `matches`, or only bare tests (`.ready`)?
   (The `trim` example's `if <entry.state matches .ready(rendered?)` binds `rendered`.)

## Answer (≤300 words to report; full version in your file)
Your recommendation on each of 1-3, with the one spelling you'd ship, shown in: an `if` that binds,
a `filter` with three alternatives, a `while`, and an assignment. Optionally check what parses today
with `bin/rig parse` in `/Users/shreeve/Data/Claude/Worktrees/rig/incredible-project-25d019`.
Goal from the owner: BEAUTIFUL, CLEAN, FLEXIBLE; one word and one mechanism per idea; least surprise.
