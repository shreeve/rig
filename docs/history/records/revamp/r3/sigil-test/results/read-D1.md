# Answers

## p01
1. `32` (12 + 0 + 20). Confidence: high
2. `bolt 4`. Confidence: high
3. Lines 20, 21, 22 (push) and 26 (restock(@items[1], 5)). Confidence: high
4. Line 32 runs once (only gear, qty 2). Line 33 prints `37 0`. Confidence: high

## p02
1. No. `find` takes `&Vec[Entry]`, a read-only lend. Confidence: high
2. Lines 16 and 18. Confidence: high
3. `top: cat 2`. Confidence: high
4. `6 3 -1`. Confidence: high

## p03
1. ann = 70, bob = 50. Confidence: high
2. Prints `failed: insufficient` (possibly shown as `Bank.insufficient`). No balance changes. Confidence: medium (error print format)
3. It passes a failure up. Confidence: high
4. Line 33 prints `ann 70` (via report(ann)); the `if` body is not run, so "check ann" is not printed. Line 35 prints `bob 45`. Confidence: high

## p04
1. It removes the first job from the queue's job list, so `q` is modified; the job is returned. Confidence: high
2. While the queue is not empty. Confidence: high
3. `ran 1 5`, then `ran 3 1`, then `ran 4 0`. Confidence: high
4. `2 0 0 false`. Confidence: high

## p05
1. When `b` is not an ASCII digit character. Confidence: high
2. Yes, it was advanced past the digits it consumed. Confidence: high
3. `49`. Confidence: high
4. `-1 -2`. Confidence: high
(Line 36 prints `700 none 0`. Confidence: medium on how `none` prints.)

## p06
1. Lines 33 and 38 (inside the `if`, if it runs). Confidence: high
2. `walk` may not modify `root` (read view) but may modify `keys` (write). Confidence: high
3. `[20, 30, 40, 50, 70] 210` (exact list formatting uncertain). Confidence: medium
4. Yes, line 38 runs (45 is not in the tree). Line 39 prints `255 true`. Confidence: high

## p07
1. `2 2`. Confidence: high
2. No. Web and db still hold handles. Confidence: high
3. Line 25 (`<web`), when the last base handle goes. Confidence: high
4. `base` is unusable after line 20, `web` after line 25, and `db` after line 28 (moved into `running`). Answer to the question asked: `db`. Confidence: high
(Full output: `2 2`, `dropped base handle`, `9 2`, `released base`, `dropped web`, `1 9`, `end of main`, `released debug`.)

## p08
1. `2 3`. Confidence: high
2. No. It changes `backup`, which has its own cloned lines. Confidence: high
3. `log` (moved on line 24). Confidence: high
4. 
```
archive app.log 2
close app.log
after archive
close tmp
end 3
close app.bak
```
Confidence: high

## p09
1. Yes: `shapes[1]` the rect becomes w=5, h=8 (w += 2, h *= 2). Confidence: high
2. `12`, `40`, `0` (one per line). Confidence: high
3. `big circle 2`. Confidence: high
4. `400 false`. Confidence: high

## p10
1. It pops the last element (stack is modified), and binds it to `x` if present. Confidence: high
2. Failure propagation. Confidence: high
3. `14` and `2`. Confidence: high
4. Line 35: `-1 -2`. Line 39: `6`. Confidence: high

## p11
1. `none`. Confidence: high
2. `rent -4`, `call -1`, `taxes 20`. Confidence: high
3. `2 8`. Confidence: high
4. Yes, line 32 pops (removes) the last task. Line 34 prints `2`. (Line 33 prints `dropped taxes 25`.) Confidence: high

## p12
1. No, `start` is an independent clone. Confidence: high
2. Lines 20, 21, 27, 28, 29, 30. Confidence: high
3. When neither player 0 nor player 1 is alive (both lives <= 0). Confidence: high
4. Line 32: `4 ana 10`. Line 33: `0 true`. Confidence: high

## Rejected programs
- r01: line 11. `a` is a read view (`&Account`); `a.balance -= n` writes through it. Confidence: high
- r02: line 18. `r` was moved on line 16 (`archive(<r)`) and `r.pages.len` uses it. Confidence: high
- r03: line 14. `cart.items.pop()` modifies the receiver and must be written `@cart.items.pop()`. Confidence: high
- r04: line 14. Pushing to `list` changes it while the view `top` (line 13) is used later on line 15. Confidence: high

## Where I hesitated
- `!` in both negation (`!x`) and postfix failure (`e!`): `transfer(...)!` and `if !in_stock(it)` are distinguished only by position.
- `@` for both write views and write calls; `@items[1]` as an argument vs `@items.push`. Fine after the guide.
- `?` as optional type, propagate none, and `??`: `digit(s[0])? * 100` took a re-read.
- `catch -1`: I first wondered whether it parsed as a subtraction. It does not.
- `d = digit(...) ?? return Parse.bad` (return as an expression).
- p06 line 8 `insert(@n.left if key < n.key else @n.right, key)`: the `@` appears in both branches of the conditional.
- p07 `+base` is a handle clone and `<base` alone is a drop; had to track counts by hand.
- p11 `for t in tasks` (bare) is a read; `postpone(@tasks[1].due, 10)` on `none` is a no-op.
- Printing of `none` and of the error value is not specified in the guide.

## Overall
Rating: 8/10. The sigils are mostly consistent and the guide covers them well. The overloaded `!` and `?` need context to read, but the position rules were enough. Tracking ownership by eye was easy because every move, clone and write is marked.
