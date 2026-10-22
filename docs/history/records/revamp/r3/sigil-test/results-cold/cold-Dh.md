# Cold reading of Rig sigils: answers

Method note: I read only the files in this folder. The session context also contained a project AGENTS.md with a sigil table. I did not open it, and I did not use it. Every meaning below is inferred from the programs. (Some later meanings match that table, which I did not use.)

## First guesses

Written after reading p01, p02 and p03 only. Not revised.

Prefix symbols (directly before a name or type):
- `&`: `&Item`, `&Vec[Item]`, `&Entry?`, `&items[0]`, `&items`. Guess: a read-only borrow, a view the callee can read but not change.
- `@`: `@Item`, `@Vec[Entry]`, `@items.push(...)`, `@ws.next()`, `@from`. Guess: a mutable borrow. `@items.push` is a mutating call on `items`, and the `@` marks it.
- `!`: `!in_stock(it)`, `!(it.qty > 3)`, `!bob.frozen`. Guess: logical not.
- `-`: `?? -1`. Guess: a negative number literal.

Postfix symbols (directly after an expression or type):
- `?` after a type: `Int?`, `Entry?`, `Box[Node]?`. Guess: optional type, a value or `none`.
- `!` after a type: `-> Int!`. Guess: fallible type, a value or a failure.
- `!` after a call: `withdraw(@from, n)!`. Guess: propagate the failure out of the enclosing function.

Keywords I did not recognize:
- `fun` (vs `sub`). Guess: `fun` returns a value; `sub` is a procedure. I was unsure whether `fun` means pure.
- `sub`: guess, a procedure with no return value.
- `struct`, `use`: guess, ordinary declarations and imports.
- `error Bank`: guess, a declared set of error values, written `Bank.frozen`.
- `as` in `if find(...) as i`: guess, binds the value inside an optional.
- `catch |e|` and `catch 0`: guess, handle a failure, with a handler block or a fallback value.
- `none`: guess, the empty optional.
- `return i if cond`: guess, return only when the condition holds.
- `while`, `for x in`, `else`, `and`, `or`: read as usual.

## Answers

### p01 — inventory

1. Line 23 prints `32`. (12 + 0 + 20.) Confidence: high.
2. Line 25 prints `bolt 4`. Confidence: high.
3. Lines 20, 21, 22 and 26. Lines 20–22 push onto `items` (`@items.push`). Line 26 calls `restock(@items[1], 5)`, which writes through `@`. Line 24 (`&items[0]`) and line 28 (`&items`) only read. Confidence: high.
4. Line 32 runs once, for `gear` (qty 2, not greater than 3). Line 33 prints `37 0`. (`value` = 4·3 + 5·1 + 2·10 = 37; `missing` stays 0 because every item has qty above 0 by then.) Confidence: high.

### p02 — word counter

1. No. `find` takes `entries: &Vec[Entry]`, a read-only view, and only reads it. Confidence: high.
2. Lines 16 and 18. Line 16 is `entries[i].count += 1` and line 18 is `@entries.push(...)`. Line 15 only passes `entries` to `find`, which cannot change it. Confidence: high.
3. Line 35 prints `top: cat 2`. The entries are the(3), cat(2), saw, dog, and, ran(1 each). The filter `count != 1 and not "the"` keeps only `cat`. Confidence: high.
4. Line 36 prints `6 3 -1`. There are six distinct words. `dog` is at index 3 and `cow` is absent, so `find` returns `none` and `?? -1` gives -1. Confidence: high.

### p03 — bank ledger

1. After line 27: `ann` has balance 70 and `bob` has balance 50. Confidence: high.
2. Line 28 prints `failed: insufficient`. No balance changes, since `to.balance += n` never runs after the failure. Confidence: the outcome is high. The exact text of the printed error is medium: it could also print as `Bank.insufficient`.
3. The trailing `!` propagates failure. It passes the failure from `withdraw(@from, n)` out of `transfer`, which is declared `sub transfer(...)!`. Confidence: high.
4. Lines 33–35 print `ann 70`, then `bob 45`. Line 33 is `!bob.frozen or report(ann) != 70`. `!bob.frozen` is false, so the right side runs. `report(ann)` prints `ann 70` and returns 70, so `!= 70` is false, and "check ann" does not print. Line 35 prints `bob 45`. Confidence: medium. It depends on `or` evaluating its right side when the left side is false, which is the normal reading.

Full output of p03, for reference: `failed: insufficient`, `45`, `failed: frozen`, `ann 70`, `bob 45`.

### p04 — job queue

1. Line 26 removes the front job from `q`. `@q.next()` lends `q` for writing, and `next` calls `jobs.remove(0)`, so `q` loses one job and `job` gets it. Confidence: high.
2. The loop continues while `q` still has jobs. `!q.is_empty()` is true while `jobs.len != 0`. Confidence: high.
3. Line 31 prints, in order: `ran 1 5`, `ran 3 1`, `ran 4 0`. Job 2 (cost 7) exceeds the budget of 5 at that point, so it is skipped by line 27–29. Confidence: high.
4. Line 33 prints `2 0 0 false`. `retry` is the skipped id 2, `skipped` is empty, `q.jobs` is empty, and the budget is 0. Confidence: high.

### p05 — expression parser

1. `digit` returns `none` when the byte is not an ASCII digit, because of `return none if !text.is_digit(b)`. Confidence: high.
2. Yes. `number(s, @pos)` lends `pos` for writing, and `number` advances it (`pos += 1`) across the digits it reads. After the call, `pos` sits at the `+` that ended the number, or at the bad or end position. Confidence: high.
3. Line 35 prints `-1 -2`. `"4+x"` fails at `x` (`?? return Parse.bad`). `"5++6"` fails with `Parse.empty`, since `number` reads nothing at the second `+`. Both are caught. Confidence: high.
4. Line 36 prints `700 none 0`. `lead("7up")` is 7·100. `lead("up7")` returns `none`. `lead("") ?? 0` is 0. Confidence: 700 and 0 are high. The printed form of `none` is medium; it might print differently.

### p06 — binary tree

1. In `main` (30–39), `root` may be modified on line 33 (`insert(@root, k)`) and line 38 (`insert(@root, 45)`). Line 31 initializes it to `none`. Lines 35, 36, 37 and 39 only read it. Confidence: high.
2. `walk` may not modify `root`, because `slot` is `&Box[Node]?`. It may modify `keys`, because `out` is `@Vec[Int]` and line 27 pushes to it. Confidence: high.
3. Line 36 prints `[20, 30, 40, 50, 70] 210`. This is an in-order walk, and the sum is 210. The values are high confidence. The list formatting is medium.
4. Yes, line 38 runs, because `contains(root, 45)` is false. It inserts 45 as the right child of 40. Line 39 prints `255 true`. Confidence: high.

### p07 — shared configuration

1. Line 19 prints `2 2`. Both services hold the `base` config with level 2. Confidence: high.
2. No. Line 20, `<base`, moves the `base` handle out and drops that handle. `web` and `db` still hold clones (`+base`), so the config stays alive. Confidence: high.
3. Line 25, `<web`. Dropping `web` releases its handle, which is the last handle to `base`, so the `drop` on `Config` prints `released base`. (Line 23 had already dropped `db`'s handle to `base`.) Confidence: high.
4. `db`. Line 28 moves it (`@running.push(<db)`). `base` and `web` were already gone (lines 20 and 25). Confidence: medium-high.

Full output of p07 for reference: `2 2`, `dropped base handle`, `9 2`, `released base`, `dropped web`, `1 9`, `end of main`, `released debug`. The last line is from the end-of-scope drop of `running`.

### p08 — files

1. Line 23 prints `2 3`. Confidence: high.
2. No. Line 22 changes `backup`'s lines (`@backup`), not `log`'s. `backup` was cloned from `log` before that, with `+log.lines`. Confidence: high.
3. `log`. Line 24 moves it into `archive`. Confidence: high.
4. From line 24 to the end, in order: `archive app.log 2`, `close app.log`, `after archive`, `close tmp`, `end 3`, `close app.bak`. The `close` lines come from the `drop` method. `archive` drops its parameter when it returns, and the last line is the end-of-`main` drop of `backup`. Confidence: high.

### p09 — shapes

1. Yes. `grow(@shapes[1], 2)` changes element 1 in place, which is the rectangle: w 3 becomes 5, h 4 becomes 8. The other elements are unchanged. Confidence: high.
2. Lines 29–30 print `12`, `40`, `0`, one per line. Confidence: high.
3. Line 32 prints `big circle 2`. Confidence: high.
4. Line 34 prints `400 false`. `$size(Pixel)` is 4 (four `U8` fields), times 100. `area(shapes[2])` is 0, so the comparison is false. Confidence: `false` is high. The 400 relies on `$size` being the byte size with no padding, which I inferred. Medium.

### p10 — stack calculator

1. Line 8 pops the top value from `stack`, when there is one (`@stack.pop()` returns an optional). If the stack is empty, `pop` yields `none`, and `take` returns `Calc.underflow`. Confidence: high.
2. A failure propagation. The `!` after the call propagates `take`'s failure out of `apply`. Confidence: high.
3. Line 33 prints `14`. Line 34 prints `2`. Confidence: high.
4. Line 35 prints `-1 -2`. `"9 +"` underflows, and `"1 2"` leaves one value over, so it fails with `leftover`. Line 39 prints `6`. The handler for `"8 2 -"` never runs, because that eval succeeds. Confidence: high.

### p11 — task list

1. `tasks[1].due` is still `none`. `postpone` only changes an existing `due`. Confidence: high.
2. Line 28 prints, in order: `rent -4`, `call -1`, `taxes 20`. Confidence: high.
3. Line 31 prints `2 8`. `open` counts the tasks not done (`call` and `taxes`), and the note `"bring id"` has 8 characters. Confidence: `2` is high. `8` is medium, because I was unsure what `Text` is. I inferred a string type.
4. Yes. `@tasks.pop()` removes the last task (`taxes`). Line 34 prints `2`. Confidence: high.

Full output of p11 from line 28 to the end, for reference: `rent -4`, `call -1`, `taxes 20`, `2 8`, `dropped taxes 25`, `2`.

### p12 — game

1. No. `start = +players` clones the vector, so later changes to `players` do not reach `start`. Confidence: high.
2. Lines 20 and 21 (`@players.push`), line 28 (`bump(@p.score, ...)`), line 29 (`target = @players[...]`, which takes a write view), and line 30 (`target.lives -= 1`). Line 27 (`for p in @players`) lends `players` for writing, so it also counts. Confidence: medium. The list is right, but the choice of which lines to include is a judgment call.
3. `done` is true when both players are dead, meaning `lives` is 0 for both. That first happens in round 4, line 31. Confidence: high.
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Trace: ana is bumped 10, 20, 30 and 40 (100 total), ben is bumped only in round 1 (10 total). Ana's lives go 2, 1, 1, 0. Ben's lives go 1, 0. Confidence: high.

## Rejected programs

- r01, line 11: `a.balance -= n`. `a` is a `&Account`, a read-only view, and this writes through it. Confidence: high.
- r02, line 18: `r.pages.len`. `r` was moved on line 16 by `archive(<r)`, so it cannot be used. Confidence: high.
- r03, line 14: `cart.items.pop()`. This mutates `cart.items` without the write sigil `@`. Every other mutating call in the programs has `@` (`@items.push`, `@stack.pop()`, `@tasks.pop()`). Confidence: medium-high.
- r04, line 14: `@list.push(...)`. This writes to `list` while `top` (`&list[1]`, a read view) is still used on line 15. The conflict is reported at the write. It could also be reported at line 15, where `top` is read. Confidence: medium on the line.

## Revised meanings

- `&x` / `&T`: a read-only borrow. The callee can read but not write. At call sites the `&` can be dropped for read parameters (`find(entries, w)`, `contains(root, 45)`), but `&` is written when you bind a view (`first = &items[0]`, `top = &list[1]`). This is one place where the notation is inconsistent.
- `@x` / `@T`: a mutable borrow. It is required at the call site for any write, including mutating method calls (`@items.push`, `@tasks.pop()`, `@ws.next()`). `@x as n` binds a writable view, and `for t in @tasks` iterates with write access.
- `<x`: a move. As a statement by itself (`<base`, `<tmp`), it moves the value and drops it at once. This was a surprise: I first read `<base` as a comparison.
- `+x`: a clone. `+log.lines` and `+players` make independent copies.
- `*T` / `*Config(...)`: a shared, reference-counted handle. Clones with `+`, and the value is released when the last handle goes. My first guess for `*` was not available, since it did not appear in p01–p03.
- `drop(@self)`: a destructor method that runs when the value is released.
- `T?` (type suffix): optional. `expr?` (postfix on an expression) propagates `none` out of the enclosing function, as in `digit(s[0])?` and `due?`. This was new; I had only guessed the type form.
- `T!` (type suffix): fallible. `expr!` (postfix on a call): propagates the failure out of the enclosing function. My first guesses for both were correct.
- `x ?? y`: default when `x` is `none` or failed. `y` can be a `return`, as in `digit(...) ?? return Parse.bad`.
- `catch e` / `catch |e| block`: handle a failure with a fallback value or a handler block.
- `fun` vs `sub`: `fun` declares a return type (`-> T`), `sub` does not. Neither is pure. `fun withdraw(a: @Account...)` takes a mutable parameter. My guess that `fun` means "pure" was wrong.
- `error E` with `E.name`: declares error values. `return E.name` returns one.
- `if x as v`: runs the branch when the optional holds a value, and binds the value to `v`. `while @ws.next() as w` loops until the optional is `none`.
- `return X if C`, `total += x if C`: a conditional return or statement. `A if C else B` is a conditional expression, and it works in lend position too (`insert(@n.left if key < n.key else @n.right, key)`).
- `match s` with `.variant(bindings) => ...`: pattern matching, with `if` guards (`.circle(r) if r > 1`) and `_` as the default arm. `@s` in `match @s` binds the variant's fields for writing.
- `$size(T)`: a builtin giving the byte size of a type. Inferred.
- `use std.text`: imports the standard text module (`text.words`, `text.is_digit`).
- `pass`: do nothing.

Which first guesses were wrong:
- `fun` as "pure": wrong. Neither `fun` nor `sub` is pure.
- `-` before a literal: right.
- `&` and `@`: right in meaning, but the call-site `&` is optional for reads, which I did not expect.
- `?` after a type: right. `?` after an expression was new.
- `!` after a call: right.
- `as`, `catch`, `none`, `return ... if`: right in general. The details were new (`catch` takes an expression or a block; `as` also works in `while`).

## Where I hesitated

- p01 line 23, `value(items)`: no `&` at the call site, though the parameter is `&`. I briefly thought this might be a problem. It is accepted, so the `&` is optional for reads.
- p02 line 10, `return i if entries[i].word == w`: I first read it as a plain `if` statement. The `return ... if` form returns the value only when the condition holds.
- p02 line 15, `if find(entries, w) as i`: I first took `as` as a type conversion.
- p02 line 29, `while @ws.next() as w`: I first read the `@` as a sigil on the loop variable, not on the call.
- p03 line 17, trailing `!` on `withdraw(@from, n)!`: I first thought it might be a negation. The context showed it propagates.
- p03 line 33, `or`: I was unsure whether `report(ann)` runs. I concluded it does, because `or` evaluates its right side when the left is false.
- p04 line 15, `@self.jobs.remove(0)` in a method: I first read `@self` as a write parameter. It is one.
- p04 line 11 vs line 25: `fun is_empty(&self)` is called as `q.is_empty()` with no sigil. Same as the read-parameter case.
- p05 line 14, `s[pos] != 43`: I first took `43` as a count. It is a byte value, '+'.
- p05 line 15, `d = digit(s[pos]) ?? return Parse.bad`: `return` on the right of `??`.
- p05 line 31, `digit(s[0])? * 100`: I first read the `?` as the optional type suffix. It is postfix propagation.
- p05 line 35, `catch -1`: I first took the `-` as a binary operator. It is a negative literal here.
- p06 line 8, `insert(@n.left if key < n.key else @n.right, key)`: the conditional passes a write lend. I had to re-read this line twice.
- p07 lines 20 and 25, bare `<base` and `<web`: I first read `<` as "less than". They are moves that drop at once.
- p07 line 17, `+base`: I first thought it was a unary plus, not a clone. The later uses showed it is a clone.
- p07 line 25: I had to think about which line releases `base`. The release is when the last handle goes.
- p08 line 24, `archive(<log)`: when the drop message prints. It prints when `archive` returns, before `after archive`.
- p09 line 34, `$size(Pixel)`: an unknown builtin. I guessed 4 bytes.
- p10 line 36–39, `catch |e|` with an indented block: I had to re-read the block's extent.
- p11 line 15, `due? - today`: I first read `due?` as an optional type. It is postfix propagation of `none` on a read view.
- p11 line 29, `Text? = Text(...)`: `Text` is not declared in the file. I assumed a standard type.
- p12 line 29–30, `target = @players[round % 2]` then `target.lives -= 1`: I first thought `target` was a copy. It is a write view into `players`.
- r01 line 11 and r03 line 14: I had to check whether the missing `@` is a rejection and not just a style choice. It is a rejection.

## Overall

Rating: 7/10 for how easy the notation was to read cold.

Why: the sigils are consistent once you see them. `&` means read, `@` means write, `<` moves, `+` copies, `?` and `!` mark optional and fallible values and their propagation. The mutating call sites are visible (`@items.push`), and that made the mutation questions easy to answer. The rejected programs are easy to pin down, because the sigil mistake is local.

What lowers the rating: `&` is optional at read call sites but required when binding a view. `fun` and `sub` differ in return type, not purity, which is not what the names suggest. A bare `<x` statement reads like a comparison at first glance. `?` and `!` are used both as type suffixes and as postfix operators on expressions, so you have to read the context to tell which is which. Some built-ins (`$size`, `Text`, `none` in print output) were not defined in the files and had to be guessed.
