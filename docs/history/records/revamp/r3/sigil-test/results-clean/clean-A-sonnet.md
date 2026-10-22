# Rig: reading it cold

## First guesses
These are from p01–p03 only, and I have not revised them.

**Prefix symbols**
- `?` before a type, as in `it: ?Item`, `entries: ?Vec[Entry]` and `best: ?Entry?`. I guessed a read-only borrow, so the callee can look but not change. It looked different from the `?` after a type in `Entry?`, which I guessed is "optional".
- `?` before an expression, as in `first = ?items[0]` and `for it in ?items`. I guessed it creates a read-only view or borrow of that thing.
- `!` before a type, as in `it: !Item`. I guessed a mutable borrow, so the callee may modify the argument.
- `!` before an expression, as in `restock(!items[1], 5)` and `!items.push(...)`. I guessed the caller explicitly marks "this may be modified here", the call-site twin of the `!` type.
- `(!ws).next()` was the same idea: lend `ws` for writing, then call `next`.
- `not` is boolean negation. I read `not it.qty > 3` as `not (it.qty > 3)`.

**Postfix symbols**
- `T?`, as in `Int?` and `Entry?`. I guessed an optional that is either a value or `none`.
- `T!`, as in `-> Int!`, and `)!` after a `sub` signature. I guessed "can fail with an error".
- `expr!` at a call site, as in `withdraw(!from, n)!` and `transfer(...)!`. I guessed "if this failed, propagate the error to my caller, like Rust's `?`". In `transfer(!ann, !bob, 30)!` inside `main`, I guessed it aborts the program on failure.

**Unfamiliar keywords and operators**
- `fun` is a function that returns a value.
- `sub` is a procedure with no return value.
- `struct` is a record type.
- `error Bank` with members is an error enum.
- `use std.text` is an import.
- `as` in `if find(...) as i` unwraps an optional and binds the value in the `if` branch.
- `??` supplies a default when the left side is `none`.
- `catch |e| ...` handles a failure and binds the error to `e`. `catch 0` supplies a fallback value.
- `none` is the empty optional.
- `return X if cond` is a postfix conditional return.
- Indentation defines blocks. The last expression of a function is its value.
- `+=` is the usual compound assignment.

## Answers

### p01 — inventory
1. Line 23 prints `32` (4·3 + 0·1 + 2·10). Confidence: high.
2. Line 25 prints `bolt 4`. Confidence: high.
3. `items` may be modified on lines 20, 21, 22 (the `!items.push`) and 26 (`restock(!items[1], 5)`). Line 24 is a read borrow, and lines 23, 28 and 33 only read. Confidence: high.
4. Line 32 runs once, for `gear`, and prints `low: gear`. Line 26 makes nut's qty 5, so `nut` and `bolt` fail `not qty > 3`.
   - Line 33 prints `37 0`: value = 12 + 5 + 20, and `missing` is still 0. Confidence: high.

### p02 — word counter
1. No. `find` takes `?Vec[Entry]`, a read-only borrow, and the calls pass no `!`. Confidence: high.
2. Lines 16 (`entries[i].count += 1`) and 18 (`!entries.push`). Confidence: high.
3. Line 35 prints `top: cat 2`. "the" is excluded, and cat is the only other word with count ≠ 1. Confidence: high.
4. Line 36 prints `6 3 -1`. There are 6 distinct words, `dog` is at index 3, and `cow` is `none`, which becomes -1. Confidence: high.

### p03 — bank ledger
1. ann = 70, bob = 50. Confidence: high.
2. Line 28 prints `failed: Bank.insufficient`, because bob has 50 and the transfer needs 80. No balance changes, since the failure is returned before the subtraction. Confidence: high on the failure and no change. Medium on the exact text of the error (it might print as `insufficient`).
3. It passes a failure on (error propagation). The `!` in `!from` before it is the one that lends for writing. Confidence: high.
4. Line 33 calls `report(ann)`, which prints `ann 70`. `70 != 70` is false and `not bob.frozen` is false, so "check ann" is not printed. Line 35 prints `bob 45`. Confidence: high.
   - Bob has 45 because line 29 withdrew 5 from 50. Line 32 failed with `Bank.frozen`.

### p04 — job queue
1. It removes the first job from `q.jobs` and returns it, so `q` is modified. The `(!q)` lends `q` for writing. Confidence: high.
2. It keeps going while the queue is not empty (`q.jobs.len != 0`). Confidence: high.
3. Line 31 prints, in order: `ran 1 5`, `ran 3 1`, `ran 4 0`. Job 2 (cost 7 > budget 5) is skipped. Confidence: high.
4. Line 33 prints `2 0 0 false`. `retry` is 2, `skipped` is then empty, `q.jobs` is empty, and `budget` is 0. Confidence: high.

### p05 — expression parser
1. When the byte is not a digit character (`text.is_digit(b)` is false). Otherwise it returns the digit value (`b - 48`). Confidence: high.
2. Yes. `pos` is passed as `!pos`, a mutable borrow, and `number` advances it. Confidence: high.
3. Line 35 prints `-1 -2`. Confidence: high.
   - `"4+x"` hits a non-digit and fails with `Parse.bad`.
   - `"5++6"` has an empty number between the pluses, so it fails with `Parse.empty`.
4. Line 36 prints `700 none 0`. Confidence: medium, because the text printed for `none` is a guess. `digit(...)?` propagates `none` out of `lead` when the digit is missing. Line 34 prints `49`.

### p06 — binary tree
1. Line 33 (`insert(!root, k)`, in a loop) and line 38 (`insert(!root, 45)`). Line 38 does run (see Q4). Confidence: high.
2. `walk` cannot modify `root`, because its parameter is `?Box[Node]?` (read-only). It can modify `keys`, because that parameter is `!Vec[Int]` and the call passes `!keys`. Confidence: high.
3. Line 36 prints `[20, 30, 40, 50, 70] 210`. Confidence: high on the values. Medium on the exact formatting of the list.
4. Yes, line 38 runs. 45 is not in the tree (path 50 → 30 → 40 → empty), so `contains` is false and `not` makes it true. Line 39 prints `255 true`. Confidence: high.

### p07 — shared configuration
1. `2 2`. Confidence: high.
2. No. `<base` only gives up this handle; `web` and `db` still hold handles to the config. It prints `dropped base handle`. Confidence: medium-high.
3. Line 25 (`<web`), which drops the last remaining handle to base. `released base` appears before `dropped web`. Confidence: medium-high.
4. `db`. Line 28 moves it into `running` with `<db`. Confidence: high.
   - `base` and `web` are already gone by then.

### p08 — files
1. Line 23 prints `2 3`. Confidence: high.
2. No. `+log.lines` makes an independent copy, so appending to `backup` leaves `log` with its 2 lines. Confidence: medium-high.
3. `log`, because `<log` moved it into `archive`. Confidence: high.
4. Output from line 24 to the end. Confidence: medium-high.
```
archive app.log 2
close app.log
after archive
close tmp
end 3
close app.bak
```
   - `close app.log` comes when `archive` finishes and its parameter is dropped.
   - `close tmp` comes from `<tmp` on line 27.
   - `close app.bak` comes when `main` ends.

### p09 — shapes
1. Yes. `grow(!shapes[1], 2)` turns the rect from (3,4) into w = 5, h = 8. Confidence: high.
2. Lines 29–30 print `12`, `40`, `0` on separate lines. Confidence: high.
3. Line 32 prints `big circle 2`. Confidence: high.
4. Line 34 prints `400 false`. `@size(Pixel)` is 4 (four U8 fields), and the dot's area is 0. Confidence: high on `false`. Medium-high on `4`.

### p10 — stack calculator
1. `pop()` removes the last element of `stack`, which is lent for writing. If there was one, it is bound to `x`. Confidence: high.
2. Failure propagation. Confidence: high.
3. Line 33 prints `14`. Line 34 prints `2` (5 − (1+2)). Confidence: high.
4. Line 35 prints `-1 -2`. `"9 +"` underflows, and `"1 2"` leaves one item on the stack, so `Calc.leftover`. Line 39 prints `6`, and no "error:" line is printed. Confidence: high.

### p11 — task list
1. `none`. The postpone does nothing when the optional is empty. Confidence: high.
2. Line 28 prints, in order: `rent -4`, `call -1`, `taxes 20`. Confidence: high.
3. Line 31 prints `2 8`. Two tasks are not done, and "bring id" has length 8. Confidence: high.
4. Yes, line 32 pops the last task off `tasks`. It prints `dropped taxes 25`, and line 34 prints `2`. Confidence: high.

### p12 — game
1. No. `+players` makes an independent copy, so later changes to `players` do not affect `start`. Confidence: medium-high.
2. Lines 20 and 21 (`!players.push`), 27 (`for p in !players`), 28 (`bump(!p.score, ...)`, which modifies a score), 29 (`!players[...]`), and 30 (`target.lives -= 1`). Line 22 is only a copy. Confidence: high.
3. When neither player is alive, i.e. both have `lives <= 0`. Confidence: high.
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Confidence: high.
   - Ben's lives go to 0 in round 1, and ana's go to 0 in round 4.
   - Ana's score is 10 + 20 + 30 + 40 = 100. Ben only got the round-1 bump, so he has 10.
   - `start` still has score 0 and lives 2, against 0 lives now.

### Rejected programs
- **r01: line 11.** `charge` takes `a: ?Account`, a read-only borrow, but writes `a.balance -= n`. Confidence: high.
- **r02: line 18.** `r.pages.len` uses `r` after `archive(<r)` moved it. Confidence: high.
- **r03: line 14.** `cart.items.pop()` modifies `items` without marking it. It needs `(!cart.items).pop()`. Confidence: medium-high.
- **r04: line 14.** `!list.push(...)` modifies `list` while the read borrow `top = ?list[1]` is still alive, because it is used on line 15. Confidence: high.

## Revised meanings
- **`?T` and `!T`** (types): confirmed. `?T` is a read-only borrow and `!T` is a mutable borrow.
- **`?x` and `!x`** (expressions and call sites): confirmed. `!` at a call site is required for any write, including method calls like `!items.push` and `(!ws).next()`. A `?` parameter may be passed without any marker (`find(entries, w)`).
- **`T?`**: optional. Confirmed.
- **`T!` and `)!`**: fallible. Confirmed.
- **`expr!`**: propagates the error. Confirmed.
- **`expr?`** (postfix on a value, as in `digit(...)?` and `due? - today`): early-out on `none`. It makes the whole expression `none`. I did not see this in p01–p03.
- **`<x`**: moves `x` away, so it cannot be used afterwards. I did not see this in p01–p03.
- **`+x`**: makes a new copy of a value, or another handle to a shared `*T`. I did not see this in p01–p03.
- **`*T` and `*Config(...)`**: a shared, reference-counted heap value. I did not see this in p01–p03.
- **`drop(!self)`**: a destructor that runs when the last owner goes away.
- **`Box[T]`**: a heap-allocated owned box, used for recursive types.
- **`self` receivers**: `!self` and `?self` have the same meaning as for any other parameter.
- **`match` with `.variant(x)`, `_`, `if` guards, and `pass`**: pattern matching on enums.
- **`a if cond else b`**: conditional expression.
- **`@size`**: compiler intrinsic.
- **`??` with `return` on the right**: an early exit.
- **`Int(b)`**: conversion from a byte.
- **`continue`**: as in other languages.

My first guesses were not wrong so much as incomplete. The main gaps were `<`, `+`, `*`, and the postfix value `?`.

## Where I hesitated
- **p01 line 6, `it: ?Item`:** on first sight I could not tell whether `?Item` meant "optional Item" or a borrow. `?Entry?` in p02 line 20 settled it, since it has both a prefix and a postfix `?`.
- **p01 line 24, `first = ?items[0]`:** I first read it as a ternary-like or optional construct. It is a read borrow.
- **p01 line 31, `not it.qty > 3`:** I had to re-read this to check precedence. I settled on `not (it.qty > 3)`, so the line runs only for `gear`.
- **p02 line 29, `(!ws).next() as w`:** I first took `!ws` as boolean negation, and only the "lend for writing" reading made sense.
- **p02 line 33, `e.count != 1 and not e.word == "the"`:** same precedence re-read. It also ran against my first expectation that `not` binds tighter.
- **p03 line 17, trailing `!`:** it is next to `!from` on the same line, so I had to separate the two meanings (lend versus propagate).
- **p03 line 28, error printing:** I was unsure whether the error prints as `Bank.insufficient` or `insufficient`.
- **p05 line 31, `digit(s[0])? * 100`:** I first thought the `?` was a ternary or a type marker. It means "give up with `none` if empty".
- **p05 line 15, `?? return Parse.bad`:** I had not seen a `return` on the right of `??` before.
- **p05 line 36, `print` of `none`:** I do not know what it prints.
- **p07 and p08, `+` and `<`:**
  - I first read `+base` as arithmetic. Only r02, p12's `start`, and p08's `backup` showed it is a copy or share.
  - I could not tell at first whether `<base` meant "less than" or a move.
  - In p07 I had to work out the reference counts by hand to find which line prints `released base`.
- **p08 line 21, `+log.lines`:** I considered that it might move the field out of `log`. p08 line 23 (`count(log)` still giving 2) and r02 pointed to a copy.
- **p09 line 19, `match !s`:** I was unsure whether the bindings `r`, `w`, `h` are copies or references. The writes `r += by` only make sense if they are references.
- **p11 line 15, `due? - today`:** this is postfix `?` on a parameter whose type is `?Int?`, and the two uses made me re-read the line.
- **p11 line 23 and 24, `postpone(!tasks[1].due, ...)`:** I had to confirm that `none` stays `none`.
- **p12 line 22, `start = +players`:** I first wondered whether it was an alias, until I worked out the `0 true` result in line 33.
- **r03:** it took a moment to see that the problem is the missing `(!cart.items)` and not a type problem.

## Overall
**Rating: 7/10.**

- **What helped:** the layout (indentation, `fun` versus `sub`) is familiar. The `?` and `!` pair is consistent: the same symbol appears in the parameter type and at the call site, so the effect of a call is visible where it is made.
- **What hurt:**
  - `?` and `!` each have several meanings depending on position (prefix on a type or value, postfix on a type, postfix on a value). This is the main source of confusion.
  - `not a > b` binding looser than `>` is easy to misread.
  - `+` and `<` could not be guessed without reading several programs and the rejected ones.
  - Several outputs, such as how `none` and errors print, cannot be determined from the code alone.
