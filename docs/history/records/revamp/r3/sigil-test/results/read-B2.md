# Answers

## p01
1. `32` (12 + 0 + 20). Confidence: high
2. `bolt 4`. Confidence: high
3. Lines 20, 21, 22 (pushes) and 26 (`restock(!items[1], 5)`). Line 24 only makes a read view. Confidence: high
4. Line 32 runs once (only gear has qty <= 3, after nut is restocked to 5). Line 33 prints `37 0`. Confidence: high

## p02
1. No. `entries` is passed as `&Vec[Entry]`, a read view. Confidence: high
2. Lines 16 and 18. (Line 15 only lends for reading.) Confidence: high
3. `top: cat 2`. Confidence: medium (top is assigned a loop element `e`; I assume it works as a view)
4. `6 3 -1`. Confidence: high

## p03
1. ann = 70, bob = 50. Confidence: high
2. Prints `failed: ` followed by the error (likely `Bank.insufficient`; exact formatting of the error value is uncertain). No balance changes (bob 50, ann 70). Confidence: medium
3. Pass a failure on (propagate). Confidence: high
4. Line 33 calls `report(ann)`, which prints `ann 70`; the condition is false so `check ann` is not printed. Line 35 prints `bob 45`. So: `ann 70` then `bob 45`. Confidence: high

## p04
1. It removes the first job from `q.jobs` (modifies `q`) and hands it back. Confidence: high
2. While the queue is not empty (`q.is_empty()` is false). Confidence: high
3. `ran 1 5`, `ran 3 1`, `ran 4 0` (job 2 is skipped). Confidence: high
4. `2 0 0 false` (retry=2, skipped now empty, q empty, budget is 0). Confidence: medium on the bool spelling

## p05
1. When `b` is not an ASCII digit. Confidence: high
2. Yes, `pos` is passed with `!pos` and `number` advances it. Confidence: high
3. `49`. Confidence: high
4. `-1 -2` ("4+x" fails with Parse.bad; "5++6" fails with Parse.empty). Confidence: high
(Line 36, for completeness: `700 none 0`; medium on how optionals print.)

## p06
1. Lines 33 and 38. Confidence: high
2. `walk` cannot modify `root` (read lend, bare arg); it may modify `keys` (`!keys`). Confidence: high
3. `[20, 30, 40, 50, 70] 210`. Confidence: high
4. Yes, line 38 runs (45 is not in the tree). Line 39 prints `255 true`. Confidence: high

## p07
1. `2 2`. Confidence: high
2. No. `web` and `db` still hold handles to base. Confidence: high
3. Line 25 (`<web`), which drops the last handle (db's was replaced on line 23). Confidence: high
4. `db` (moved into `running`). (`base` and `web` were already unusable earlier.) Confidence: high

## p08
1. `2 3`. Confidence: high
2. No. `+log.lines` clones, so appending to `backup` leaves `log` alone. Confidence: high
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
Confidence: high

## p09
1. Yes: `shapes[1]` (rect 3,4) becomes rect(5, 8) (w += 2, h *= 2). Confidence: high
2. `12`, `40`, `0` (three lines). Confidence: high
3. `big circle 2`. Confidence: high
4. `400 false`. Confidence: high

## p10
1. `pop()` removes the last element of `stack`; if there was one it is bound to `x`. Confidence: high
2. Failure propagation. Confidence: high
3. Line 33: `14`. Line 34: `2`. Confidence: high
4. Line 35: `-1 -2`. Line 39: `6`. Confidence: high

## p11
1. `none` (postpone on a none does nothing). Confidence: high
2. `rent -4`, `call -1`, `taxes 20`. Confidence: high
3. `2 8`. Confidence: high
4. Yes, it pops the last task (taxes). Line 33 prints `dropped taxes 25`. Line 34 prints `2`. Confidence: high

## p12
1. No. `+players` is a clone. Confidence: high
2. Lines 20, 21, 27–28 (`for p in !players`, `bump(!p.score ...)`), and 29–30 (`target = !players[...]`, `target.lives -= 1`). Line 22 only clones. Confidence: high
3. `done` is true when neither player is alive (both lives <= 0). Confidence: high
4. Line 32: `4 ana 10`. Line 33: `0 true`. Confidence: high

## Rejected programs
- r01: line 11. `a` is `&Account` (read only), but `a.balance -= n` writes through it. Confidence: high
- r02: line 18. `r` was moved into `archive(<r)` on line 16, so `r.pages.len` uses a moved value. Confidence: high
- r03: line 14. `cart.items.pop()` changes `cart.items` without the write marker; it needs `(!cart.items).pop()`. Confidence: high
- r04: line 14. The push may change/move `list` while the read view `top` (line 13) is still used on line 15. Confidence: high

## Where I hesitated
- p02 line 34 `top = e`: assigning a loop view to an `Entry?` variable looked like it should need a `&`; I assumed it is allowed.
- p05 line 31 `digit(s[0])? * 100`: first read `?` as part of a type; it is "return none if none". Unsure how an optional prints (I guessed `700 none 0`).
- p06 line 8 `!n.left if key < n.key else !n.right`: parsed as a conditional expression of write lends, not a negation.
- p06 line 35/37 `walk(root, ...)`: bare read lend, which the guide covers.
- p03 line 33: `not bob.frozen or report(ann) != 70` precedence of `not` vs `or`; also error print format.
- p01 line 31 `not it.qty > 3`: re-read per guide (`not` binds loosely).
- p09 `.circle(r) => r += by` — binding r as a write view in `match !s`.
- p04 whether bools print as `false` or `False`.

## Overall
Rating: 8/10. The sigils (`!` write, `&` read, `<` move, `+` clone, trailing `!`/`?`) were mostly consistent, and the guide made marking of every change easy to scan. The overloaded `!` (write lend, fallible type, propagate) and `?` (optional, propagate none) needed context, and `not` precedence plus the `(!v).pop()` parenthesised form took an extra look.
