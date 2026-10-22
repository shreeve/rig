# Answers

## p01
1. `32` (4*3 + 0*1 + 2*10). Confidence: high
2. `bolt 4`. Confidence: high
3. Lines 20, 21, 22 (pushes) and 26 (`restock(!items[1], 5)`). Line 19 only creates it. Confidence: high
4. Line 32 runs once (only gear, qty 2, has qty <= 3 after restock); it prints `low: gear`. Line 33 prints `37 0`. Confidence: high

## p02
1. No. `find` takes `?Vec[Entry]`, a read view. Confidence: high
2. Lines 16 and 18. (Line 15 only reads.) Confidence: high
3. `top: cat 2`. Confidence: high
4. `6 3 -1`. Confidence: high

## p03
1. ann = 70, bob = 50. Confidence: high
2. Prints `failed: insufficient` (possibly shown as `Bank.insufficient`). No balance changes (bob has 50, needs 80). Confidence: medium
3. It passes a failure up (the `!` after a value). Confidence: high
4. Line 33 calls `report(ann)`, which prints `ann 70`. 70 != 70 is false, and `not bob.frozen` is false, so line 34 does not run. Line 35 prints `bob 45`. So the output is:
```
ann 70
bob 45
```
Confidence: medium (assumes `not` applies only to `bob.frozen`, so `report(ann)` is evaluated)

## p04
1. It removes the first job from `q.jobs` and returns it (queue pop-front), changing `q`. Confidence: high
2. While `q` is not empty (`q.jobs.len != 0`). Confidence: high
3. In order:
```
ran 1 5
ran 3 1
ran 4 0
```
(job 2 costs 7 > 5, so it is skipped.) Confidence: high
4. `2 0 0 false`. Confidence: high

## p05
1. When `b` is not an ASCII digit. Confidence: high
2. Yes. `pos` was passed as `!pos`, so `number` advances it. Confidence: high
3. `49`. Confidence: high
4. `-1 -2` ("4+x" fails with bad, "5++6" fails with empty). Confidence: high

(Line 36, not asked, prints `700 none 0`. Confidence: medium on how `none` prints.)

## p06
1. Lines 33 (insert in loop) and 38 (if executed). Line 31 only initialises it. Confidence: high
2. `walk` may not modify `root` (bare argument is a read). It may modify `keys` (passed as `!keys`). Confidence: high
3. `[20, 30, 40, 50, 70] 210`. Confidence: medium (exact list print format)
4. Yes, line 38 runs because 45 is not in the tree. Line 39 prints `255 true`. Confidence: high

## p07
1. `2 2`. Confidence: high
2. No. `web` and `db` still hold handles to base. Confidence: high
3. Line 25 (`<web`), which drops the last handle to base. Confidence: high
4. `db` (it was moved into `running`). `base` and `web` are already unusable earlier. Confidence: high

(Not asked: after `end of main`, `released debug` is printed when `running` is dropped.)

## p08
1. `2 3`. Confidence: high
2. No. `+log.lines` is a clone, and the append on line 22 changed only `backup`. Confidence: high
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

## p09
1. Yes. `shapes[1]` changes from rect(3,4) to rect(5,8): `w += 2`, `h *= 2`. Confidence: high
2. 
```
12
40
0
```
Confidence: high
3. `big circle 2`. Confidence: high
4. `400 false`. Confidence: high

## p10
1. It pops the top of the stack (changing it). `x` is bound if there was an element; otherwise it falls through to fail with underflow. Confidence: high
2. Failure propagation. Confidence: high
3. Line 33 prints `14`. Line 34 prints `2`. Confidence: high
4. Line 35 prints `-1 -2`. Line 39 prints `6`. Confidence: high

## p11
1. `none`. Line 24's postpone does nothing on a `none` due. Confidence: high
2. In order:
```
rent -4
call -1
taxes 20
```
Confidence: high
3. `2 8`. Confidence: high
4. Yes, it pops the last task ("taxes"). Line 33 prints `dropped taxes 25`. Line 34 prints `2`. Confidence: high

## p12
1. No. `start = +players` is a clone, an independent copy. Confidence: high
2. Lines 20, 21, 27 (write loop), 28 (`bump(!p.score, ...)` through `p`), 29 (the write view `target`), 30 (`target.lives -= 1`). Line 22 only reads `players` to clone it. Confidence: medium (whether 27 and 29 count versus 28 and 30)
3. When neither player is alive (both lives <= 0). Confidence: high
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Confidence: high

## Rejected programs
- r01: line 11 (`a.balance -= n`). `a` is a read view `?Account`, which cannot be written through. Confidence: high
- r02: line 18 (`r.pages.len`). `r` was moved on line 16 by `archive(<r)`. Confidence: high
- r03: line 14 (`cart.items.pop()`). `pop` changes its receiver, so it needs a write marked as `(!cart.items).pop()`. Confidence: high
- r04: line 14 (`!list.push(...)`). `top` is a lasting read view of `list[1]` still used on line 15, so `list` cannot change. Confidence: high

## Where I hesitated
- p03 line 33, `not bob.frozen or report(ann) != 70`: I first wondered whether `not` covers the whole `or` expression. The guide says `not` binds looser than a comparison but does not say how it ranks against `or`. I assumed `not` covers only `bob.frozen`.
- p01 line 24 vs 26: I had to check that the view `first` is last used on line 25, so the write on line 26 is allowed.
- p05 line 15, `digit(...) ?? return Parse.bad`: `return` on the right side of `??` was unusual, but I read it as an early exit.
- p05 line 31, `digit(s[0])? * 100`: I checked that `?` binds tighter than `*`.
- p06 line 8, `insert(!n.left if key < n.key else !n.right, key)`: a conditional that picks between two write lends. I had to re-read it.
- p06 lines 35 and 37: `root` is passed bare (read) and `keys` as `!keys`.
- p07: I had to count handles and track when base's last handle dies. I first thought line 20 might print `released base`. I also wondered whether `db.config = +debug` drops the old handle (I assumed yes).
- p08 line 24: the `archive` parameter is by value, so the drop message ("close app.log") prints inside `archive`'s end, not in `main`.
- p10 line 8, `(!stack).pop() as x`: the guide covered this form.
- p11 line 26: `for t in tasks` (no sigil) is a read. Line 27, `open += 1 if not t.done`, mixes a trailing `if` with `not`.
- p12 lines 27-30: `for p in !players` then `target = !players[...]` creates a lasting write view. I wondered whether `alive(target)` could conflict. I assumed not, because a bare argument is a read from the same view.
- How optionals and errors print (`none`, `Bank.insufficient`) is not in the guide.

## Overall
Rating: 8/10. The sigils are consistent: `!` always means write and `?` means read or optional. Call sites show which calls can change a value, which made the "where is it modified" questions easy. The harder parts were `not` precedence against `or`, tracking handle counts in p07, and a few uncommon forms such as `?? return`.
