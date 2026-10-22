# Answers

## p01 — inventory
1. Line 23 prints `32` (4*3 + 0*1 + 2*10). Confidence: high
2. Line 25 prints `bolt 4`. Confidence: high
3. Lines 20, 21, 22, 26. Confidence: high
4. Line 32 runs once (only for gear, qty 2). Line 33 prints `37 0` (after restock the nut has qty 5, so value is 12+5+20 = 37; missing is 0). Confidence: high

## p02 — word counter
1. No. `find` takes `&Vec[Entry]`, a read view, so it cannot modify `entries`. Confidence: high
2. Lines 16 and 18. Confidence: high
3. Line 35 prints `top: cat 2`. Confidence: high
4. Line 36 prints `6 3 -1`. Confidence: high

## p03 — bank ledger
1. ann = 70, bob = 50. Confidence: high
2. Line 28 prints `failed: insufficient` (the exact error format, e.g. `Bank.insufficient`, is not certain). Bob has 50 and wants to send 80, so withdraw fails. No balance changes. Confidence: medium (message format)
3. It passes a failure on. Confidence: high
4. Line 32 prints `failed: frozen`. Lines 33-35 print `ann 70` (from `report(ann)` in the condition) and then `bob 45` (line 35). "check ann" is not printed. Confidence: medium (depends on how `not` groups with `or`; if `not` covered the whole `or` expression, `report(ann)` would be skipped and only `bob 45` would print)

## p04 — job queue
1. It lends `q` for writing and removes and returns the first job. `q` loses that job, and the job moves into `job`. Confidence: high
2. The loop keeps going while the queue is not empty. Confidence: high
3. In order: `ran 1 5`, `ran 3 1`, `ran 4 0`. Job 2 (cost 7) is skipped. Confidence: high
4. `2 0 0 false` Confidence: high

## p05 — expression parser
1. When `b` is not a digit character (`text.is_digit(b)` is false). Confidence: high
2. Yes. `pos` is passed with `!`, so `number` advances it. Confidence: high
3. Line 35 prints `-1 -2`. Confidence: high
4. Line 36 prints `700 none 0`. The exact rendering of the `none` is a guess. Confidence: medium

## p06 — binary tree
1. Lines 33 and 38. Confidence: high
2. `walk` may not modify `root` (it takes a read view). It may modify `keys` (passed with `!`). Confidence: high
3. Line 36 prints `[20, 30, 40, 50, 70] 210`. Confidence: medium (list print format)
4. Yes, line 38 runs because 45 is not in the tree. Line 39 prints `255 true`. Confidence: high

## p07 — shared configuration
1. `2 2` Confidence: high
2. No. Two other handles (`web`, `db`) still hold it. Confidence: high
3. Line 25 (`<web`), which drops the last handle. Confidence: high
4. `db` (moved at line 28). Confidence: high

## p08 — files
1. `2 3` Confidence: high
2. No. `backup` has its own clone of the lines. Confidence: high
3. `log` (moved into `archive`). Confidence: high
4. In order:
```
archive app.log 2
close app.log
after archive
close tmp
end 3
close app.bak
```
Confidence: high (the last line comes from `backup` being dropped at the end of main)

## p09 — shapes
1. Yes. The rect at index 1 changes from 3x4 to w=5, h=8. Confidence: high
2. Lines 29-30 print `12`, `40`, `0` on separate lines. Confidence: high
3. `big circle 2` Confidence: high
4. `400 false` Confidence: high

## p10 — stack calculator
1. It is lent for writing, and `pop` removes the top element from it. Confidence: high
2. Failure propagation. Confidence: high
3. Line 33 prints `14`. Line 34 prints `2`. Confidence: high
4. Line 35 prints `-1 -2`. Line 39 prints `6`. Confidence: high

## p11 — task list
1. `none`. Postponing a task with no due date does nothing. Confidence: high
2. In order: `rent -4`, `call -1`, `taxes 20`. Confidence: high
3. `2 8` Confidence: high
4. Yes, it removes the last task (taxes). Line 33 prints `dropped taxes 25`. Line 34 prints `2`. Confidence: high

## p12 — game
1. No. `+players` is a clone, so `start` is independent. Confidence: high
2. Lines 20, 21, 27-28 (`bump(!p.score, ...)` through `!players`) and 29-30 (`target` is a write view of an element, and line 30 changes `target.lives`). Confidence: medium (whether to list 29 and 30 together)
3. When both players' lives are 0 or less (neither is alive). Confidence: high
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Confidence: high

## Rejected programs
- r01: line 11. `charge` takes `a: &Account`, a read view, but line 11 changes `a.balance`. Confidence: high
- r02: line 18. `r` was moved on line 16 (`archive(<r)`) and is used afterwards (`r.pages.len`). Confidence: high
- r03: line 14. `cart.items.pop()` changes the cart but has no write marker; it should be `(!cart.items).pop()`. Confidence: high
- r04: line 14. `!list.push(...)` changes `list` while the view `top` (line 13) is still used on line 15. Confidence: high

## Where I hesitated
- p03 line 33: `not bob.frozen or report(ann) != 70`. I wasn't sure whether `not` covers just `bob.frozen` or the whole `or`. The guide says `not` binds looser than a comparison, but says nothing about `or`/`and`. I assumed it covers only `bob.frozen`.
- p01 line 31 and p02 line 33: `not it.qty > 3` reads like `(not it.qty) > 3` at first. I had to apply the guide's rule to read it as `not (it.qty > 3)`.
- p05 line 31: `digit(s[0])? * 100`. I had to work out that `?` here returns early with `none` and that the `*` is then multiplication. Also unsure how `none` is printed on line 36.
- p05 line 15: `?? return Parse.bad`. `return` used as the right-hand side of `??` was unusual.
- p07 line 20: `<base` alone on a line. The guide says this drops now. I first read it as a move with no target.
- p07 line 23: `db.config = +debug`. I had to work out that the old handle is dropped on assignment.
- p06 line 8: `!n.left if key < n.key else !n.right` as an argument. A conditional expression with `!` lends was dense.
- p06 lines 35 and 37: `walk(root, !keys)` with bare `root` for a `&` parameter. The guide says a bare argument is a read lend, so this was fine, but I double-checked.
- p11 line 26: `for t in tasks` with no `&`. The guide shows `&v` and `!v` for loops, so I assumed bare is a read.
- p12 line 29: `target = !players[round % 2]` is a lasting write view, and `players[...]` is then modified at line 30 through `target`. I wasn't sure how to count this for "lines where players may be modified".
- p04 line 15 and p10 line 8: `(!x).method()` is easy to confuse with `!x.method()` (a method that changes the receiver). I read the former as "lend now, use the result".
- p09 line 19: `match !s` with `r += by`. I assumed `r` binds to the field in place.
- r04: unsure whether to blame line 13 (making the view) or line 14 (the push); I chose 14.
- p11 line 29: `Text` versus `String` types. I assumed they behave alike.

## Overall
Rating: 7/10. The sigils mostly read well once the guide's table is internalized: `!` for write, `<` for move, and `&` for read are visually distinct, and the changes are clearly marked at call sites. The main difficulty was the overlap of symbols (`!` as write lend, fallible propagation and fallible type; `?` for optional and propagation) and the parenthesized `(!v).pop()` form. Operator precedence for `not` was also underspecified in the guide.
