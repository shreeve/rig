# Review 2 of for-iter (857d86e8)

Verdict: SOUND for the probed class. No soundness finding. Two cosmetic notes.

Built 857d86e8 in a detached worktree (zig build -j4 clean). Ran 99 review-1 probes plus about 85 new
(kept in review-for-iter-2-probes/). Every accepted program was run under RIG_SANITIZE=1, debug and --release.

## Review-1 findings
- S1 (kept view past a made iterator's `break`): d03, d06, d07, j03, b06, j01, j02 are all rejected now
  ("`for iterator` does not live long enough ... while `keep` still views it"). Fixed.
- D1 (spans past EOF): every diagnostic is on the `for` line; files with no trailing newline, CRLF and multibyte text are right
  (t01-t03, i01-i03). Message names `for iterator`, not `__rig_iterN`.
- H1 (hidden-name capture): `__rig_iter0` is now an ordinary user name (h01, h02, f02 declare a fresh local; no effect on the loop);
  `for iterator` cannot be lexed (s01). Fixed.
- Remaining accepted review-1 probes all clean; the only rc=124 are the intentional infinite loops (a15, b12, e17).

## New shapes (all rejected unless noted)
- kept through `break` with value (n03, p07), `break it` as loop value (p01), `return it` (n02, m07 accepted only when the view
  is of a lent parameter: prints a, clean), field store `h.v = it` (n05, p04), store through `!` param (p06), nested for
  with break / labeled break out (n07, m04, m05, m17, m19, p08, m13 else block), `<b` and place iterators (m15, m16, m08 accepted:
  view of a place, clean), generic `Gen[T]` made (n09, p03), closures capturing `it` or `keep` (m02, m02b, p12, p14, p15),
  push into a Vec (m22), `continue` (n11, q06).
- Accepted and clean (drops once, correct order, debug and release): nested made loops with break, labeled break out of three
  levels, continue :label, return from nested, error source in else (q01, q03, q04, q07-q10, r01, r03-r06, p02, p13, m09, m20).

## Notes (not findings)
1. Caret columns are inside the `for` keyword and differ by one between an error and its note
   (e.g. error 65:5, note 65:4 for a `for` at column 3). Same line, so a user finds it; cosmetic.
2. Generic function `fun go[T](g: !T)` with `for x in g` is rejected ("cannot iterate over `!T`"): a limitation, not unsound.
3. The oracle still marks made-source functions unknown (block); not re-checked here.
