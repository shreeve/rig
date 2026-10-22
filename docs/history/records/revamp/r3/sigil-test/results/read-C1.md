# Answers

## p01 — inventory
1. Line 23 prints `32` (12 + 0 + 20). Confidence: high
2. Line 25 prints `bolt 4`. Confidence: high
3. Lines 20, 21, 22 (pushes) and 26 (`restock(@items[1], 5)`). Line 24's `&items[0]` is only a view. Confidence: high
4. Line 32 runs once (only gear has qty <= 3, since nut was restocked to 5). It prints `low: gear`. Line 33 prints `37 0`. Confidence: high

## p02 — word counter
1. No. `find` takes `&Vec[Entry]`, a read view, and the call passes `entries` bare, so it is only read. Confidence: high
2. Lines 16 (`entries[i].count += 1`) and 18 (`@entries.push(...)`). Confidence: high
3. Line 35 prints `top: cat 2`. Confidence: high
4. Line 36 prints `6 3 -1`. Confidence: high

## p03 — bank ledger
1. ann 70, bob 50. Confidence: high
2. Line 28 prints `failed: insufficient` (bob has 50 < 80; exact formatting of the error value is a guess, possibly `Bank.insufficient`). No balance changes. Confidence: medium
3. It passes the failure on (propagates the error). Confidence: high
4. Line 33's condition is false (`not bob.frozen` is false; `report(ann)` prints and returns 70, so `!= 70` is false), so line 34 does not print. Output: `ann 70` (from report in line 33), then `bob 45` (line 35). Confidence: high

## p04 — job queue
1. It removes the first job from `q.jobs` and returns it (modifies `q`). Confidence: high
2. While the queue is not empty. Confidence: high
3. `ran 1 5`, `ran 3 1`, `ran 4 0` (job 2 costs 7 > 5, so it is skipped). Confidence: high
4. `2 0 0 false`. Confidence: high

## p05 — expression parser
1. When `b` is not a digit character. Confidence: high
2. Yes, `pos` is advanced (passed with `@pos`, the callee changes it). Confidence: high
3. `49`. Confidence: high
4. Line 35 prints `-1 -2`. Line 36 prints `700 none 0` (the printed form of an absent optional is a guess). Confidence: medium

## p06 — binary tree
1. Line 33 (`insert(@root, k)`, five times) and line 38 (`insert(@root, 45)`, which does run). Confidence: high
2. `walk` may not modify `root` (read view, passed bare); it may modify `keys` (passed with `@`). Confidence: high
3. `[20, 30, 40, 50, 70] 210`. Confidence: medium (list print format guessed)
4. Yes, line 38 runs (45 is not in the tree). Line 39 prints `255 true`. Confidence: high

## p07 — shared configuration
1. `2 2`. Confidence: high
2. No. `web` and `db` still hold handles on base. Confidence: high
3. Line 25 (`<web`) drops the last handle on base, so `released base` prints before `dropped web`. (Line 23 replaced db's handle, line 25 removes web's.) Confidence: high
4. `db` (moved by `<db` on line 28). Confidence: high

## p08 — files
1. `2 3`. Confidence: high
2. No. `+log.lines` clones the lines, so `backup` is independent. Confidence: high
3. `log` (moved into `archive`). Confidence: high
4. Output from line 24 on:
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
1. Yes. `shapes[1]` (the rect) becomes `rect(w: 5, h: 8)`. Confidence: high
2. `12`, `40`, `0` (three lines: 12, then 40, then 0). Confidence: high
3. `big circle 2`. Confidence: high
4. `400 false`. Confidence: high

## p10 — stack calculator
1. The top element is popped off `stack` (it is modified). Confidence: high
2. A failure propagation. Confidence: high
3. Line 33 prints `14`; line 34 prints `2`. Confidence: high
4. Line 35 prints `-1 -2`; line 39 prints `6`. Confidence: high

## p11 — task list
1. `none` (the call task has no due date, so postpone does nothing). Confidence: high
2. `rent -4`, `call -1`, `taxes 20`. Confidence: high
3. `2 8`. Confidence: high
4. Yes: it pops (removes) the last task, `taxes`. Output of line 33 is `dropped taxes 25`. Line 34 prints `2`. Confidence: high

## p12 — game
1. No. `+players` clones, so `start` is independent. Confidence: high
2. Lines 20, 21, 27 and 28 (the loop over `@players` with `bump(@p.score, ...)`), and lines 29 and 30 (`target = @players[...]`, `target.lives -= 1`). Confidence: high
3. When neither player is alive (both have lives <= 0). Confidence: high
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Confidence: high

## Rejected programs
- r01: line 11. `a` is `&Account`, a read view, so `a.balance -= n` cannot modify it. Confidence: high
- r02: line 18. `r` was moved by `archive(<r)` on line 16, so `r.pages` is use-after-move. Confidence: high
- r03: line 14. `cart.items.pop()` changes the vector but is not marked as a write; it should be `@cart.items.pop()`. Confidence: high
- r04: line 14. Pushing to `list` (a write) while the view `top = &list[1]` is still used on line 15 violates read-view/write exclusion. Confidence: high

## Where I hesitated
- `@` vs `&` at first: I had to keep remembering `@` is write and `&` is read (in many languages `&` is the generic reference). Not wrong, but needed re-reading.
- `<name` alone on a line (p07 line 20, p08 line 27) means drop; `<x` in an argument or binding means move. Same symbol, two roles by position.
- p07: whether `<base` printed "released base" at line 20; I first thought maybe yes, then saw the `+base` clones are extra handles.
- p02 lines 33-34: `top = e` assigns a view into an optional; unclear how it works, but I took it as bound to the loop's element.
- p11 line 26 `for t in tasks` (bare) vs `&tasks`: guide says bare is read, so fine. `due? - today` precedence of `?` read as postfix on `due`.
- p05 line 15 `?? return Parse.bad`: a return inside a `??` right side; I took it as early exit when digit is none.
- p05 line 36 and p06 line 36: exact print formatting of `none` and of a Vec is not specified.
- p03 line 28: exact formatting of the printed error value is not specified.
- `not a == b` binding looser than comparisons (p01 line 31, p02 line 33) needed the guide's rule; first instinct would be `(not a) == b`.
- p12 line 29 `target = @players[...]` is a write view binding; I took it as a lasting write view.

## Overall
Rating: 7/10. The sigils `&` for read and `@` for write, plus the rule that every change is marked, made it quick to see where things get modified. Dual use of `<` and the unspecified print formats of none, errors and vectors caused most of the hesitation.
