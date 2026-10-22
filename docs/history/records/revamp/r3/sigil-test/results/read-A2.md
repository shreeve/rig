# Answers

## p01 — inventory

1. Line 23 prints `32` (12 + 0 + 20). Confidence: high
2. Line 25 prints `bolt 4`. Confidence: high
3. Lines 20, 21, 22 (pushes) and 26 (`restock(!items[1], 5)`). Line 24 only takes a view. Confidence: high
4. Line 32 runs once (only gear has qty 2, which is not above 3; nut is now 5). Line 33 prints `37 0` (12 + 5 + 20 = 37; missing = 0 because every item is in stock after the restock). Confidence: high

## p02 — word counter

1. No. `find` takes `?Vec[Entry]`, a read view, so it cannot modify `entries`. Confidence: high
2. Line 16 (`entries[i].count += 1`) and line 18 (`!entries.push(...)`). Line 15 only reads. Confidence: high
3. Line 35 prints `top: cat 2`. Confidence: high
4. Line 36 prints `6 3 -1`. Entries in order: the, cat, saw, dog, and, ran. Confidence: high

## p03 — bank ledger

1. After line 27: ann = 70, bob = 50. Confidence: high
2. Line 28 prints `failed: insufficient` (bob has 50 and needs 80; the exact text of the error value may be `Bank.insufficient`). No balance changes. Confidence: medium (exact error formatting)
3. Pass a failure on (the `!` after the call). Confidence: high
4. Line 33's condition: `not bob.frozen` is false (frozen is true), so `report(ann)` runs and prints `ann 70`. It returns 70, so `!= 70` is false and "check ann" is not printed. Line 35 prints `bob 45` (bob had 50 and withdrew 5 on line 29). Output:
```
ann 70
bob 45
```
Confidence: high

## p04 — job queue

1. Line 26 removes the first job from the front of `q.jobs` (modifying `q`) and returns it as `job`. Confidence: high
2. The loop keeps going while the queue is not empty. Confidence: high
3. Line 31 prints, in order:
```
ran 1 5
ran 3 1
ran 4 0
```
(job 2 costs 7 against a budget of 5, so it is skipped.) Confidence: high
4. Line 33 prints `2 0 0 false`. Confidence: high

## p05 — expression parser

1. When `b` is not a digit character (`text.is_digit(b)` is false). Confidence: high
2. Yes. `pos` is passed as `!pos`, so `number` advances it. Confidence: high
3. Line 35 prints `49`. Confidence: high
4. Line 36 prints `-1 -2`. ("4+x": `x` is not a digit, so it fails with Parse.bad. "5++6": an empty number between the two `+` fails with Parse.empty.) Confidence: high

Note: the question numbering says line 35 and 36; line 34 prints `49` and line 35 prints `-1 -2`, and line 36 prints `700 none 0`. Per the question's line numbers:
- Line 35 prints `-1 -2`.
- Line 36 prints `700 none 0`.

So, corrected for the actual lines: 3. Line 35 prints `-1 -2`. 4. Line 36 prints `700 none 0` (the `none` rendering is a guess). Confidence: high for line 35, medium for line 36 (how `none` prints)

## p06 — binary tree

1. Lines 33 (`insert(!root, k)`, inside the loop) and 38 (`insert(!root, 45)`). Confidence: high
2. `walk` cannot modify `root` (it is passed as a bare read argument). It may modify `keys` (passed as `!keys`). Confidence: high
3. Line 36 prints the sorted keys and the sum: `[20, 30, 40, 50, 70] 210` (the vector's exact formatting is a guess). Confidence: medium
4. Yes, line 38 runs, because `contains(root, 45)` is false. Line 39 prints `255 true`. Confidence: high

## p07 — shared configuration

1. Line 19 prints `2 2`. Confidence: high
2. No. `web` and `db` still hold handles to the config. Confidence: high
3. Line 25 (`<web`) drops the last handle, so `released base` prints there (before `dropped web`). Line 23 replaced db's handle earlier. Confidence: high
4. `db` (it was moved into `running` on line 28). Confidence: high

## p08 — files

1. Line 23 prints `2 3`. Confidence: high
2. No. `+log.lines` clones the lines, so `backup` has its own copy. Confidence: high
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

1. Yes. `shapes[1]` changes from `rect(3,4)` to `rect(5,8)` (w += 2, h *= 2). Confidence: high
2. Lines 29-30 print `12`, `40`, `0` on three lines. Confidence: high
3. Line 32 prints `big circle 2`. Confidence: high
4. Line 34 prints `400 false`. Confidence: high

## p10 — stack calculator

1. `stack` is modified: the last element is popped (removed), and the popped value is bound to `x` if there was one. Confidence: high
2. Failure propagation. Confidence: high
3. Line 33 prints `14`. Line 34 prints `2`. Confidence: high
4. Line 35 prints `-1 -2`. Line 39 prints `6` (the `catch` block does not run, so no "error:" line). Confidence: high

## p11 — task list

1. `none`. `postpone` on a `none` due does nothing. Confidence: high
2. Line 28 prints, in order:
```
rent -4
call -1
taxes 20
```
Confidence: high
3. Line 31 prints `2 8`. Confidence: high
4. Yes. Line 32 pops the last task (taxes) off `tasks`. Line 33 prints `dropped taxes 25`. Line 34 prints `2`. Confidence: high

## p12 — game

1. No. `+players` is a clone, so `start` is an independent copy. Confidence: high
2. Lines 20 and 21 (pushes), 27-28 (`for p in !players` with `bump(!p.score, ...)`), and 29-30 (the write view `target` and `target.lives -= 1`). Lines 22 and 31 do not modify it. Confidence: high
3. `done` is true when neither player is alive (both `lives` are 0 or less). Confidence: high
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Confidence: high

## Rejected programs

- r01: line 11 (`a.balance -= n`). `a` is a read view (`?Account`), so it cannot be written to. Confidence: high
- r02: line 18. `r` was moved on line 16 by `archive(<r)`, so `r.pages.len` uses a moved value. Confidence: high
- r03: line 14. `cart.items.pop()` changes `cart.items` without the write mark; it should be `(!cart.items).pop()`. Confidence: high
- r04: line 14. `top` is a lasting read view of `list[1]` that is used on line 15, so pushing to `list` on line 14 modifies it while the view is live. Confidence: high

# Where I hesitated

- p05 question numbering: the questions say lines 35 and 36 but the printing of the sum is on line 34; I answered by the actual line numbers and noted it.
- p03 line 33, `not bob.frozen or report(ann) != 70`: I had to work out that `not` applies only to `bob.frozen` and that `or` short-circuits, so I checked whether `report(ann)` runs (it does, because the left side is false).
- p05 line 15, `?? return Parse.bad`: I read `return` as allowed on the right of `??` (exits the function). Not wrong, but unusual.
- p05 line 31, `digit(s[0])? * 100`: I first wondered about precedence, then decided `?` binds to the call before `*`.
- p05 line 36, p06 line 36, p03 line 28: I did not know how `none`, a Vec or an error value are printed by `print`. These are guesses.
- p06 line 8, `insert(!n.left if key < n.key else !n.right, key)`: I read this as picking one of two write lends.
- p08 line 21, `+log.lines`: I first wondered whether it was a clone of `log` or of its `lines`; it is the field.
- p12 lines 29-30: `target = !players[round % 2]` is a lasting write view, so `players` is not read on line 30 while it lives. I had to check that line 31's read of `players` comes after `target`'s last use.
- p01 line 31, `not it.qty > 3`: re-read the guide's note that `not` binds looser than a comparison.
- p11 line 15, `due? - today`: I first thought `?` was a lend; it is "pass none up".

# Overall

Rating: 7/10. The sigils are mostly consistent (`!` write, `?` read, `<` move, `+` clone), and the guide's table made most programs readable at once. The hard parts were the same symbols in different positions (`?` as a read lend, as an optional type, and as "pass none up"; `!` as a write lend and as "pass failure up") and the parenthesized `(!v).pop()` form. Rules about when a lasting view is still live (r04, p12) needed careful reading.
