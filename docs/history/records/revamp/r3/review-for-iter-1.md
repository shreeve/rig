# Review 1 of for-iter (ebc35dda on a2398d67)

Verdict: DO NOT MERGE. One soundness hole (use after free), two diagnostic/hygiene defects.
About 110 probes (kept in .git/revamp/r3/review-for-iter-1-probes/), debug and --release under RIG_SANITIZE=1, plus rig-oracle on each accepted one. Built both bins clean.

## S1 (SOUNDNESS): a view kept past a made iterator's `break` is a use after free
Minimal (probes d03, d06, d07, b06, j03):

    keep: (?Item)? = none
    for it in mkbuf()          # Buf.next(!self) -> (?Item)?  yields ?self.buf[i]
      keep = it
      break
    if keep as k
      print(k.name)            # accepted; debug: "use of freed memory" crash; --release: garbage / empty

Also with `break if cond` inside an `if` (d07), with `else` (d06), and a `break` in a function that then
reads `keep` and returns (j03; release prints -6148914691236517206).
Rejected correctly: no `break` (loan carried round the back edge, b01), `continue` (d04),
a conditional `break if` directly in the loop (c03), `return it` (b02), `break it` (b03), nested in another loop (j01, j02).

Hand-written equivalent is rejected (d01): `if true` / `h = mkbuf()` / `while (!h).next() as it` / `keep = it` / `break`
gives "`h` does not live long enough". So the rewrite is not checked as the while it claims to be:
the generated `(block (set h ..) while)` node loses the loan on `h` at the unconditional/`break` exit out of the block
(the "leaving a scope never silently forgets a loan" rule). Likely in the ownership checker's walk of a `block`
whose scope is left by `break`, versus an `if` body. The oracle cannot catch it: main is
"unknown (an expression without a type: block)", so every made-source function is undecided by the oracle.
Fix the class: the break/exit path out of a block scope must report the scope's live loans; add d03/d06/d07/j03 as
reject tests and a matrix cell (made source x break x kept view). Also check the labelled form and `<it`
(b04 was rejected only through the back edge; test with `break`).

## D1: diagnostics point into the appended text and name `__rig_iterN` (contradicts the PR's claim)
Probes b01, b02, b03, b05, c03, d04, j01, j02. Example (b02):

    error: cannot return a view of `__rig_iter0`, which this function was not lent
    next __rig_iter0 __rig_iter0          <- line 71, past the end of a 68-line file
                       ^

The error's line:col is beyond the file and the snippet is the appended `next __rig_iter0 ...` text. Any error whose
span is a hidden node does this (loan notes, "does not live long enough", write-while-read). The user never wrote
`__rig_iter0`; the span should be the loop's source and the message should say "the iterator of this `for`".
`--facts` also lists leaf positions past the source end.

## H1: the hidden name is capturable by user code
Probe h01: inside a made-source loop, `__rig_iter0 = upto(100)` is accepted and assigns the hidden iterator
(the loop never ends); h02 same with an owned Tracked (drops 7 repeatedly). Without the loop it would declare a fresh
local. Probe f02: a user local `__rig_iter0 = 5` before the loop gives "type mismatch: expected Int, got Count" and
"type `!Int` has no method `next`" at the appended text. Not memory-unsafe (types still checked), but "accept means
correct" fails and a user name changes the loop. A user local named `next` is fine (f01). Fix: make the hidden
name unspellable (a name the lexer cannot produce) or reject `__rig_` names in source; keep a test.

## Checked and fine (no finding)
- Drops of a made `h` on end, `break`, labelled break out of nested loops, `return`, failure `!`, `catch` in the source
  (a01-a03, a05, a06, a08, f08-f13): exactly one drop each, order inner first, sanitizer clean, debug and release.
- `<it` then use of `it` is rejected (a07, e23); `<it` in an outer loop body rejected as moved in a previous iteration (e04, f07).
- Place iterator holding `?Vec`: pushing in the body rejected (given reject test); `w` broken out of then Vec changed while `w`
  is used later rejected (a13); reassigning, moving, or calling `next` on the iterator while a yielded view is live
  is rejected (a16, b09, b10, b11, c04, c07, e15).
- Nested loops over the same place iterator share state (a04), same for Cell-holding `*Holder` fields (g04, g05, g07).
- Generic iterator `Cnt[T]` over String and Int, owned String items kept or broken out with (a09, a10): clean.
- Rejected with sensible messages: `?it`, `xs[i]`, `.field` of a made value, by-value or `?T` parameter, `*Gen` handle, index
  binding, `T` generic param (e07 only says "cannot iterate over `!T`").
- Error positions after the loop (lines after), CRLF, a file with no trailing newline, and multibyte text before/after
  the loop are right (i01-i03). A user function or local named `next` is fine (e03, f01).
- Oracle: no `compiler accepts, oracle rejects` difference on any probe; but see S1 for its blind spot (block => unknown).

## Notes
- e17/h01-style infinite loops (reassigning the iterator in the body) are ordinary semantics for the in-place desugaring.
- Not exercised: module-level rewrite across imports with errors in both modules (the shipped test covers the happy path).
