# Panel brief: five close calls in Rig (2026-11-04)

Rig is an indentation-sensitive systems language that compiles to Zig, with
Python/Ruby readability, Zig/C's cost model, and Rust's memory safety
without a GC. Ownership is visible as one-character sigils at the place it
happens: `?x` lends a view to read, `!x` lends a view to write, `<x` moves,
`+x` clones; `@` is self, and a method's self mode is written `?@` / `!@`
(see docs/QUICK.md and docs/learn/01-sigils.md). The owner's taste
(AGENTS.md): one word and one mechanism per idea; a mark for a mechanic,
a word for a library; least surprise; no punctuation doing a keyword's job;
Rig should be the most consistent language for humans and AIs to write.

Repository (read only; do not edit anything): /Users/shreeve/Data/Code/rig at
origin/main. Read first: docs/QUICK.md, docs/CORE.md (fixed: the ownership
model), docs/design/mantras.md, and the SPEC.md sections each item names. You
may run `bin/rig` from a checkout if one is built, but reasoning from the docs
is enough.

The lead's recommendations, to be confirmed or challenged:

1. `!` on a `for` source. Today `for x in ?b.each()` gives `?` to the
   call's self (each gets b lent to read), but in `for x in !b.counter()` the
   `!` is taken as the LOOP's mode (iterate with write views of the items),
   so a program whose `counter` needs `b` lent to write is rejected.
   (AGENTS.md Pitfalls: "a `for` source sigil moves into the loop's mode".)
   SPEC: search "for" loops and loop modes. RECOMMENDATION: when the source
   is a call, the sigil goes to the call's self, as `?` does; the loop's
   write mode stays for a plain place (`for x in !xs` = iterate with write
   views). A SPEC edit; no real program in the owner's code uses the
   rejected form.

2. `collect` of views. With `names: List[String]`,
   `names.filter(f).collect()` builds a `List[?String]` (views into names,
   not copies). SPEC "Chains" says collecting views is rejected; the
   compiler accepts it; it is memory-safe (the ownership checker keeps names
   lent while the collected list lives; the reference checker agrees).
   RECOMMENDATION: SPEC says what the code does: allow it (zero-copy), rather
   than force a clone of each element.

3. The check-speed guard as a merge gate. bench/check/guard.py counts the
   instructions `rig check` retires on a fixed generated program (1-2 minutes,
   load-insensitive). It was not a required gate, and check speed drifted 27%
   (10-15 to 10-31) unnoticed. RECOMMENDATION: require it for compiler PRs,
   beside the json/hash/text speed guards.

4. A dedicated check-speed round. `rig check` does about 12% more work than
   on 10-13, spread over features (each about 1%); a focused round on 11-01
   cut 19%. RECOMMENDATION: one round after the compiler revamp's phase 2,
   once features settle, measured on Trig's real check (about 2 s).

5. Two write captures of one value in `task.select`:
       task.select(
         a.recv(|!n, v| ...),
         b.recv(|!n, v| ...))
   A select builds every arm (its closure) before it runs one, so two write
   views of `n` live at once. Main accepted this and it crashed.
   CORE allows one write view at a time. RECOMMENDATION: keep rejecting it
   (only one arm ever runs, but both closures exist at once); a program lets
   one arm write `n`, or returns values and writes `n` after the select.

Your task: from your expertise, for each item say AGREE or DISAGREE with
the recommendation, with your reasons (what your language does, what users
would expect, the costs, risks, and any better alternative). Be candid: these
are close calls and a reasoned disagreement is valuable. Write your full
answer (at most 400 words) to the file your brief names, then return just a
5-line verdict: one line per item, "N: AGREE|DISAGREE: one-sentence reason".
