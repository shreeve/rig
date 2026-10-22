# Answers

## p01 — inventory
1. `32` (12 + 0 + 20). Confidence: high
2. `bolt 4`. Confidence: high
3. Lines 20, 21, 22, 26. Confidence: high
4. Line 32 runs once (only gear has qty <= 3 after the restock). Line 33 prints `37 0`. Confidence: high

## p02 — word counter
1. No. `find` takes `&Vec[Entry]`, a read view, so it cannot modify `entries`. Confidence: high
2. Lines 16 and 18. Confidence: high
3. `top: cat 2`. Confidence: high
4. `6 3 -1`. Confidence: high

## p03 — bank ledger
1. ann = 70, bob = 50. Confidence: high
2. Prints `failed: Bank.insufficient` (bob has 50 < 80). The error is caught, and no balance changes. Confidence: medium (exact error text format)
3. It passes a failure up: the `!` suffix on the call means propagate the failure. Confidence: high
4. Line 33 calls `report(ann)`, which prints `ann 70`. The condition is false, so "check ann" is not printed. Line 35 prints `bob 45`. So the output is `ann 70` then `bob 45`. Confidence: high

## p04 — job queue
1. It removes the first job from the queue's `jobs` and returns it, so it modifies `q` (the `@` marks the write). Confidence: high
2. While the queue is not empty (`!q.is_empty()`). Confidence: high
3. `ran 1 5`, then `ran 3 1`, then `ran 4 0` (job 2 is skipped). Confidence: high
4. `2 0 0 false` Confidence: high

## p05 — expression parser
1. When `b` is not a digit character (`text.is_digit(b)` is false). Confidence: high
2. Yes. `pos` is passed with `@`, so `number` advances it. Confidence: high
3. `49` Confidence: high
4. `-1 -2` ("4+x" hits a bad digit; "5++6" gives an empty number at the second `+`.) Confidence: high

(Line 36, not asked: `700 none 0`. Confidence: medium on how `none` prints.)

## p06 — binary tree
1. Lines 33 and 38 (line 38 only if it runs). Confidence: high
2. `walk` may not modify `root`, because it takes a read view `&`. It may modify `keys` (passed with `@`). Confidence: high
3. `[20, 30, 40, 50, 70] 210`. Confidence: medium (list print format)
4. Yes, line 38 runs because 45 is not in the tree. Line 39 prints `255 true`. Confidence: high

## p07 — shared configuration
1. `2 2` Confidence: high
2. No. `web` and `db` still hold handles to base. Confidence: high
3. Line 25 (`<web` drops the last handle to base). Confidence: high
4. `db` (moved on line 28). Confidence: high

## p08 — files
1. `2 3` (the backup got a clone of 2 lines and then one more). Confidence: high
2. No. `+log.lines` is a clone, so `log` is unaffected. Confidence: high
3. `log` (moved on line 24). Confidence: high
4. In order:
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
1. Yes. `grow` changes the rect at index 1 from (3,4) to (5,8): w += 2, h *= 2. Confidence: high
2. `12`, `40`, `0` (one per line). Confidence: high
3. `big circle 2` Confidence: high
4. `400 false` Confidence: high

## p10 — stack calculator
1. A value is popped (removed) from the stack; `stack` is modified. Confidence: high
2. Failure propagation. Confidence: high
3. Line 33: `14`. Line 34: `2`. Confidence: high
4. Line 35: `-1 -2`. Line 39: `6`. Confidence: high

## p11 — task list
1. `none` (postpone does nothing for a `none` due). Confidence: high
2. `rent -4`, `call -1`, `taxes 20` (taxes' due was 15 + 10 = 25). Confidence: high
3. `2 8` Confidence: high
4. Yes, `pop` removes the last task. Line 34 prints `2`. (Line 33 prints `dropped taxes 25`.) Confidence: high

## p12 — game
1. No. `+players` is a clone, so it is independent. Confidence: high
2. Lines 20, 21, 27 (for `@players`, with line 28 changing `p.score`), 29 and 30 (`target` is a write view into `players`). Confidence: medium on 27/28/29 (the exact set)
3. `done` is true when neither player is alive (both lives <= 0). Confidence: high
4. Line 32: `4 ana 10`. Line 33: `0 true`. Confidence: high

## Rejected programs
- r01: Line 11. `a` is a read view (`&Account`), so `a.balance -= n` is a write through it. Confidence: high
- r02: Line 18. `r` was moved by `<r` on line 16, so `r.pages.len` uses a moved value. Confidence: high
- r03: Line 14. `cart.items.pop()` changes the receiver and needs the `@` mark: `@cart.items.pop()`. Confidence: high
- r04: Line 14. `top` is a lasting read view of `list[1]` still used on line 15, so `list` may not change (push) in between. Confidence: high

## Where I hesitated
- p05 line 15 `?? return Parse.bad`: I thought `??` needs a value on the right. It seems `return` is allowed there to exit the function.
- p05 line 31 `digit(s[0])? * 100`: I had to work out that `?` binds to the call first, then multiplies.
- p06 line 8 `insert(@n.left if key < n.key else @n.right, key)`: an `@` on each branch of an inline conditional. Unusual but readable.
- p06 line 35 `walk(root, @keys)`: bare `root` is a read argument next to `@keys`; I had to recall the "bare means read" rule.
- p02 line 34 `top = e`: I was unsure whether this stores a view or a copy, and about line 31's `Entry?` being `&Entry?`.
- p07: telling which `<` and `+` drop or add handles, and tracking the last handle.
- `@` versus `&` in patterns (p09 line 19 `match @s` with `r += by`): I first wondered if `r` was a copy. It is a write alias.
- p12 line 29 `target = @players[...]`: I decided it is a lasting write view, so line 30 modifies `players`.
- Print formats for `none`, lists, errors: I guessed.

## Overall
Rating: 8/10. The sigils are consistent: `@` marks every change, `&` marks a view, `<` marks a move, `!` and `?` mark failure and none. This made "where is it modified" questions easy to answer by scanning for `@`. The costs were bare-argument-means-read, which I had to keep in mind, and the dense `?`/`!`/`??` suffix operators.
