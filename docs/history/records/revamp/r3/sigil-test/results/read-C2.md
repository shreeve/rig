# Answers

## p01 — inventory
1. `32` (12 + 0 + 20). Confidence: high
2. `bolt 4`. Confidence: high
3. Lines 20, 21, 22 (pushes) and 26 (`restock(@items[1], 5)`). Line 24 only makes a read view. Confidence: high
4. Line 32 runs once (only gear, qty 2, passes `not it.qty > 3`; it prints `low: gear`). Line 33 prints `37 0`. Confidence: high

## p02 — word counter
1. No. It takes `&Vec[Entry]`, a read view. Confidence: high
2. Lines 16 and 18. Line 15 only reads through `find`. Confidence: high
3. `top: cat 2`. Confidence: high
4. `6 3 -1`. Confidence: high

## p03 — bank ledger
1. ann = 70, bob = 50. Confidence: high
2. `failed: insufficient` (possibly shown as `Bank.insufficient`). No balance changes, since bob's 50 < 80 fails before the subtraction. Confidence: medium (exact error text format)
3. Pass a failure on. Confidence: high
4. Line 33 prints `ann 70` (from `report(ann)`, and "check ann" is not printed). Line 35 prints `bob 45`. Output:
```
ann 70
bob 45
```
Confidence: high

## p04 — job queue
1. It removes and returns the first job from `q`'s queue (modifies `q`). Confidence: high
2. While `q` is not empty. Confidence: high
3. In order:
```
ran 1 5
ran 3 1
ran 4 0
```
(job 2 costs 7 > 5 and is skipped.) Confidence: high
4. `2 0 0 false`. Confidence: high

## p05 — expression parser
1. When `b` is not a digit character. Confidence: high
2. Yes, it was passed as `@pos` and `number` advances it. Confidence: high
3. `49`. Confidence: high
4. `700 none 0`. Confidence: medium (how `none` is printed)
Line 35 prints `-1 -2`. Confidence: high

## p06 — binary tree
1. Lines 33 and 38 (inserts). Confidence: high
2. `walk` may not modify `root` (read view). It may modify `keys` (passed `@keys`). Confidence: high
3. `[20, 30, 40, 50, 70] 210` (list formatting is a guess). Confidence: medium
4. Yes, line 38 runs (45 is not in the tree). Line 39 prints `255 true`. Confidence: high

## p07 — shared configuration
1. `2 2`. Confidence: high
2. No; web and db still hold handles. Confidence: high
3. Line 25 (`<web`, the last handle to base goes). Confidence: high
4. `db` (moved into the vector on line 28). (`base`, `web` already unusable earlier.) Confidence: high

## p08 — files
1. `2 3`. Confidence: high
2. No; `+log.lines` is a clone, so `backup` has its own copy. Confidence: high
3. `log`. Confidence: high
4. Output:
```
archive app.log 2
close app.log
after archive
close tmp
end 3
close app.bak
```
Confidence: high

## p09 — shapes
1. Yes: `shapes[1]` (rect) becomes rect(w: 5, h: 8). Confidence: high
2. `12`, `40`, `0` on three lines. Confidence: high
3. `big circle 2`. Confidence: high
4. `400 false`. Confidence: high

## p10 — stack calculator
1. The last element is popped off (removed), modifying `stack`; if there was one it is bound to `x`. Confidence: high
2. Failure propagation. Confidence: high
3. Line 33 prints `14`; line 34 prints `2`. Confidence: high
4. Line 35 prints `-1 -2`; line 39 prints `6`. Confidence: high

## p11 — task list
1. `none` (postpone on a none does nothing). Confidence: high
2. In order:
```
rent -4
call -1
taxes 20
```
Confidence: high
3. `2 8`. Confidence: high
4. Yes, it pops (removes) the last task. Line 32 prints `dropped taxes 25`; line 34 prints `2`. Confidence: high

## p12 — game
1. No. `+players` is a clone, so `start` is independent. Confidence: high
2. Lines 20, 21, 27, 28 (via `@p.score`), 29 and 30 (via the write view `target`). Confidence: medium (29 only creates the write view; 30 does the change)
3. When both players have no lives left (lives <= 0). Confidence: high
4. Line 32: `4 ana 10`. Line 33: `0 true`. Confidence: high

## Rejected programs
- r01: line 11. `a` is a read view (`&Account`) and `a.balance -= n` writes through it. Confidence: high
- r02: line 18. `r` was moved by `archive(<r)` on line 16, so `r.pages.len` uses a moved value. Confidence: high
- r03: line 14. `cart.items.pop()` changes `cart` but is not marked with `@` (should be `@cart.items.pop()`). Confidence: high
- r04: line 14. `top` is a lasting read view of `list[1]` and is used on line 15, so `list` may not be changed (pushed) while it is alive. Confidence: high

## Where I hesitated
- p05 line 15 `?? return Parse.bad`: I took it to mean return the error if the digit is none; the guide does not show `return` on the right of `??`.
- p05 line 31 `digit(s[0])? * 100`: the `?` propagates none from `lead`; how `none` prints on line 36 is a guess.
- p03 line 17 `withdraw(@from, n)!`: `!` after a call with an `@` argument, so "write" and "failure" are both nearby; I settled on failure propagation.
- p03 line 33 `not bob.frozen or report(...)`: precedence of `not` with `or`, and short-circuiting.
- p10 line 36-38 `catch |e|` followed by an indented block whose last line `0` is the value; guessed from context.
- p08 and p07: bare `<x` alone on a line is a drop, versus `f(<x)` a move; had to re-read to be sure which line triggers each drop message. Also the implicit drop of `f` at the end of `archive`.
- p12 line 29 `target = @players[...]`: a lasting write view in a binding; I took it as legal since no other use of `players` before line 30.
- p06 line 8 `@n.left if key < n.key else @n.right`: a conditional expression yielding write views.
- p09 `.circle(r) => r += by` with `match @s`: assumed r binds as a writable view.
- Exact printing format of lists, errors and `none`.

## Overall
Rating: 8/10. The sigils (`&` read, `@` write, `<` move, `+` clone) are consistent, and seeing `@` at each call site makes it easy to spot what can change. The main costs were a few unusual forms (`?? return`, `catch |e|` blocks, `if ... else` with views) and not knowing exact print formats.
