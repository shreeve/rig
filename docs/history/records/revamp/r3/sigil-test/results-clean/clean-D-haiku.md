## Step 1: First guesses

**Prefix symbols**
- `&` (e.g. `it: &Item`, `&items[0]`, `report(&top)`): a read-only borrow or reference. It appears in parameter types and in expressions.
- `@` (e.g. `it: @Item`, `@items.push(...)`, `restock(@items[1], 5)`): a mutable borrow or reference. Functions that take `@` parameters appear to mutate the caller's value. I'm unsure whether `@` is just a marker at the call site or a real operator.
- `!` (e.g. `!in_stock(it)`, `!(it.qty > 3)`, `!bob.frozen`): logical NOT.

**Postfix symbols**
- `?` on a type (`Int?`, `Entry?`): an optional type, which may be `none`.
- `!` on a type (`-> Int!`, `sub transfer(...)!`): a fallible result type that can produce an error.
- `!` on an expression (`withdraw(@from, n)!`): propagate the error, like a `try`.
- `??` (`find(...) ?? -1`): a default when the left side is `none`. It's binary, so it is not really postfix.
- `+=`, `-=`: compound assignment.

**Keywords I don't recognize**
- `sub`: a procedure that may mutate its `@` arguments, as opposed to `fun`. The `fun`/`sub` split is my best guess.
- `fun`: a function with a `->` return type. I'm guessing its last expression is its return value.
- `struct`, `error`: type and error-enum declarations.
- `use`: an import (`use std.text`).
- `none`: the empty optional value.
- `as`: pattern binding in `if x as e` and `while @ws.next() as w`.
- `catch`, with `|e|` binding: error handling. `catch 0` gives a default.
- `return X if cond`: a conditional return.
- `if`/`else`, `while`, `for x in`: standard control flow, indentation-delimited with no braces.

## Step 2: Answers to questions.md

Method: I had only the Read tool, so I did not run these programs. Every output below is worked out by hand from the code. Where the exact text of a printed value depends on formatting the code doesn't show, I say so.

**p01 — inventory**
1. Line 23 prints `32`. (4·3 + 0·1 + 2·10.) Confidence: high.
2. Line 25 prints `bolt 4`. Confidence: high.
3. Lines **20, 21, 22, 26**. Lines 20–22 push onto `items`, and line 26 calls `restock(@items[1], …)`. Line 19 only initializes it. Confidence: high.
4. Line 32 runs **once** (only `gear`, qty 2, fails `qty > 3`) and prints `low: gear`. Line 33 prints `37 0`. Confidence: high.

**p02 — word counter**
1. **No.** `find` takes `entries: &Vec[Entry]`, which is read-only. Confidence: high.
2. Lines **16** (`entries[i].count += 1`) and **18** (`@entries.push(...)`). Confidence: high.
3. Line 35 prints `top: cat 2`. Only `cat` has count ≠ 1 and is not `the`. Confidence: high.
4. Line 36 prints `6 3 -1`. There are 6 distinct words, `dog` is at index 3, and `cow` is absent. Confidence: high.

**p03 — bank ledger**
1. After line 27: **ann = 70, bob = 50**. Confidence: high.
2. Line 28 prints `failed: insufficient` (bob has 50, needs 80). **No balance changes.** The outcome is high confidence; the exact text of the printed error variant is medium, since the code doesn't say how an error value prints.
3. The last character of line 17 is `!` and it **passes a failure on** (propagates it up to `transfer`, which is itself fallible). Confidence: high.
4. Lines 33–35 print `ann 70` (line 33 calls `report(ann)` because `!bob.frozen` is false, so the `or` evaluates its right side), then `bob 45` (line 35). `check ann` is not printed, since 70 ≠ 70 is false. Confidence: high.

For completeness, the whole program prints: `45` (line 30), `failed: frozen` (line 32), then the lines 33–35 output above.

**p04 — job queue**
1. Line 26 **removes the first job from `q`** (via `next(@self)`, which calls `remove(0)`) and returns it. Confidence: high.
2. The loop continues **while the queue is non-empty** (`!q.is_empty()`, i.e. `q.jobs.len != 0`). Confidence: high.
3. Over the loop, line 31 prints, in order: `ran 1 5`, `ran 3 1`, `ran 4 0`. Job 2 (cost 7 > budget 5) is skipped via `continue`. Confidence: high.
4. Line 33 prints `2 0 0 false`. `retry` is the skipped job id 2, `skipped.len` is 0 after the removal, `q.jobs.len` is 0, and `budget` is 0. Confidence: high.

**p05 — expression parser**
1. Line 8: `digit` returns `none` when `b` is **not an ASCII digit** (`text.is_digit(b)` is false). Confidence: high.
2. **Yes.** `number(s, @pos)` advances `pos` past the digits it consumed, stopping at a `+` or the end of the string. Confidence: high.
3. Line 35 prints `-1 -2`. `"4+x"` fails on `x` (bad). `"5++6"` fails because the number is empty (empty). Confidence: high.
4. Line 36 prints `700 none 0`. Values are high confidence: `lead("7up")` = 700, `lead("up7")` = none, and `lead("") ?? 0` = 0. The printed form of `none` is a guess, so this is medium.

**p06 — binary tree**
1. Lines **33** (`insert(@root, k)`) and **38** (`insert(@root, 45)`). Line 31 only initializes `root`. Confidence: high.
2. `walk` **may not** modify `root` (it takes `&`). It **may** modify `keys` (it pushes via `@out`). Confidence: high.
3. Line 36 prints `[20, 30, 40, 50, 70] 210`. The values are high confidence; the Vec format is a guess, so the line is medium.
4. **Yes**, line 38 runs. `contains(root, 45)` is false before it's inserted. Line 39 prints `255 true`. Confidence: high.

**p07 — shared configuration**
1. Line 19 prints `2 2`. Confidence: high.
2. **No.** Line 20 releases only the variable's handle. `web` and `db` still hold the `base` handle, so the count stays above zero. Confidence: high.
3. Line **25** (`<web`). After line 23 `db` no longer points to `base`, so `web` holds the last `base` handle. Dropping `web` releases it and prints `released base`. Confidence: medium (this assumes that dropping a struct releases its fields' handles).
4. **`db`**. It is moved into `running` on line 28. Confidence: high.

**p08 — files**
1. Line 23 prints `2 3`. Confidence: high.
2. **No.** `+log.lines` makes a copy, so line 22 only changes `backup`. Confidence: high.
3. **`log`**, which is moved into `archive` on line 24. Confidence: high.
4. From line 24 to the end, in order:
   ```
   archive app.log 2
   close app.log
   after archive
   close tmp
   end 3
   close app.bak
   ```
   The `close` lines assume that `drop` runs when a by-value parameter goes out of scope and when a live local is dropped at the end of `main`. Confidence: medium.

**p09 — shapes**
1. **Yes.** `grow(@shapes[1], 2)` changes the rectangle from 3×4 to **w = 5, h = 8**. Confidence: high.
2. Lines 29–30 print `12`, `40`, `0` on separate lines. Confidence: high.
3. Line 32 prints `big circle 2`. The first arm matches, so the `_` arm does not run. Confidence: high.
4. Line 34 prints `400 false`. `$size(Pixel)` is 4 bytes (four `U8` fields), and the `dot` area is 0. The units of `$size` are assumed to be bytes, so this is medium.

**p10 — stack calculator**
1. Line 8 **pops the top element** off `stack` and binds it to `x`. If the stack is empty, it returns `underflow`. Confidence: high.
2. The last character of line 13 is `!`, a **failure propagation**. Confidence: high.
3. Line 33 prints `14`. Line 34 prints `2`. Confidence: high.
4. Line 35 prints `-1 -2`. Line 39 prints `6`. The `"8 2 -"` evaluation succeeds, so the `catch` block on lines 36–38 does not run. Confidence: high.

**p11 — task list**
1. After line 24, `tasks[1].due` is **`none`**. `postpone` does nothing to a `none` value. Confidence: high.
2. Over the loop, line 28 prints, in order: `rent -4`, `call -1`, `taxes 20`. Confidence: high.
3. Line 31 prints `2 8`. Two tasks are open, and `"bring id"` has 8 characters. Confidence: high.
4. **Yes.** Line 32 pops the last task (`taxes`). Line 34 prints `2`. Confidence: high.

**p12 — game**
1. **No.** `start = +players` is an independent copy, so later changes to `players` do not affect `start`. Confidence: high.
2. Lines **20, 21** (pushes), **28** (`bump(@p.score, …)`), and **30** (`target.lives -= 1`). Line 19 only initializes `players`. Lines 27 and 29 hand out mutable access, but the actual writes happen on lines 28 and 30. Confidence: medium, because "may be modified" could be read to include the loop and binding lines.
3. `done` is true when **both players are out of lives** (neither is `alive`). Confidence: high.
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Trace: ana ends with score 100 and 0 lives, ben ends with score 10 and 0 lives. `leader` returns `ana`. Line 33 compares `start`'s copy (lives 2) with the final lives (0). Confidence: high.

**Rejected programs**
- **r01, line 11** (`a.balance -= n`). `a` is a `&Account`, a read-only borrow, so it cannot be written through. Confidence: high.
- **r02, line 18** (`r.pages.len`). `r` was moved into `archive` by `<r` on line 16, so it can't be used afterward. Confidence: high.
- **r03, line 14** (`cart.items.pop()`). This mutating method call has no `@` receiver marker. The rule is inferred from every other mutating method call in the set (`@items.push`, `@stack.pop()`, `@tasks.pop()`, `@q.next()`). Confidence: medium.
- **r04, line 14** (`@list.push(...)`). `top = &list[1]` is still needed on line 15, so a shared borrow is alive while the list is mutated. Confidence: high.

## Step 3

### Revised meanings

- **`&x`**: a read-only borrow. It lasts only until its last use. In p01 `first` is used on line 25, and the mutation on line 26 is legal because `first` is not used afterward. r04 is rejected for the opposite case.
- **`@x`**: a mutable borrow, used at call sites and on mutating method receivers (`@items.push`). **Plain field assignments need no `@`** (`bob.frozen = true`, `a.balance -= n` in a `@` param, `db.config = …`). This split was not in my first guesses.
- **Bare name to a `&` parameter** is an implicit shared borrow (`value(items)`, `report(ann)`).
- **`!` prefix**: logical NOT. `!=` is not-equal, as expected.
- **`T?`, `none`, `as`**: optional type, empty value, and pattern binding for the payload. My first guesses were right.
- **`x?` postfix** on an optional, inside a function that returns an optional: propagate `none` early (p05 line 31, p11 line 15). I had guessed this as "propagate" without knowing it's for `none`.
- **`T!` and `E!`**: a fallible return type, and a propagating call (p03 line 17, p10 line 13). **`catch`** handles an error with a default value or a `|e|` block. My first guesses were right.
- **`??`**: default for `none`. Its right side may be `return X` (p05 line 15). I was right that it's binary.
- **`fun` vs `sub`**: `fun` has a `->` return type; `sub` has none. **Mutation is not tied to `sub`**. `fun next(@self)` (p04) and `fun number(pos: @Int)` (p05) both take mutable parameters. **My guess that `sub` means "may mutate" was wrong.**
- **`+x`**: a value copy for collections (p08 backup, p12 start), and a new reference for `*` handles (p07 `+base`). Not in my first guesses.
- **`*expr`**: creates a shared, reference-counted handle (type `*T`) (p07). Not in my first guesses.
- **`<x`**: moves `x` out (ends its ownership). If it was the last owner, the value's `drop` runs (p07 `<web`, p08 `archive(<log)`). Not in my first guesses.
- **`drop(@self)`**: a destructor, run when the last owner goes away (p07, p08, p12).
- **`struct`, `enum`, `error`**: declarations. `error Bank` values are used as `Bank.frozen`. `enum` variants are matched with `.variant(x) => …` arms, which can have `if` guards (p09). `_` is a wildcard and `pass` is a no-op.
- **`use std.text`**: import. `text.words`, `text.is_digit`.
- **`$size(T)`**: a size intrinsic (p09). I read it as bytes.
- **`[a, b]`**: an array literal. **`0..n`**: exclusive range.
- **`Vec()`, `Vec[T]`, `.len`** (property, no parentheses), **`.push`, `.pop()`, `.remove(i)`, `.next()`** (methods). **`Int(x)`**: conversion.
- **Implicit return**: the last expression of a block is its value (`sum`, `n`, `a.balance`).
- **Indentation** delimits blocks.

### Where I hesitated

- **p01 l.19**: `items: Vec[Item] = Vec()`. I treated initialization as not a modification.
- **p01 l.23**: `value(items)` passes a bare name where the parameter is `&`. I read this as an implicit shared borrow.
- **p01 l.24–26**: the borrow `first = &items[0]` ends at its last use on line 25, so line 26 is legal.
- **p02 l.15**: `find(entries, w)` passes an `@` parameter to a `&` parameter. I read this as allowed.
- **p02 l.34**: `top = e` assigns a borrowed `Entry` into an owned `Entry?`. Copy and borrow read the same here, and the output is the same either way.
- **p03 l.17**: the trailing `!` could be "not" or "propagate". It is propagate, since it follows a call and the expression has no value to negate.
- **p03 l.28, l.32**: the printed form of an error value (`insufficient` vs `Bank.insufficient`) is not shown anywhere.
- **p03 l.33**: `or` short-circuits, but here the left side is false, so `report(ann)` runs and prints `ann 70` from inside an `if` condition.
- **p04 l.26**: `job = @q.next()` looks like a read, but it removes an element.
- **p04 l.29**: `continue` skips the `budget -=` line, which changes the output.
- **p05 l.8**: `return none if !text.is_digit(b)`. The `!` applies to the call only.
- **p05 l.12**: `start = pos`, where `pos` is `@Int`. I read this as a copy. If it were an alias, `pos == start` would always hold, and the function would always return `Parse.empty`.
- **p05 l.15**: `d = digit(s[pos]) ?? return Parse.bad`. The `return` on the right of `??` is hard to parse on first contact.
- **p05 l.31**: `digit(s[0])? * 100`. The postfix `?` binds tighter than `*`.
- **p05 l.36**: the printed form of `none` and of optional values is not specified.
- **p06 l.8**: `insert(@n.left if key < n.key else @n.right, key)`. A conditional expression is used directly as a mutable argument.
- **p06 l.10**: `slot = Box(...)` assigns through an `@` parameter without an `@` on the assignment.
- **p06 l.36**: the Vec print format is a guess.
- **p07 l.20**: `<base` could mean "move" or "destroy". I read it as releasing one owner; `drop` runs only at zero.
- **p07 l.17**: `+base` could be a copy or a new handle. The field type `*Config` settled it as a handle.
- **p07 l.25**: I assume that dropping a struct releases the handles in its fields. This drives the answer to Q3.
- **p08 l.21**: `+log.lines` could be shared or copied. Line 23 prints `count(log)` as 2, which only works if it is a copy.
- **p08 l.24**: the `close app.log` line assumes that a by-value parameter is dropped at the end of `archive`.
- **p08 end of `main`**: whether locals are dropped at program end, and in what order, is not shown. I assumed `backup` is dropped.
- **p09 l.27**: `[ ... ]` is an array, not a `Vec`. This does not change any output.
- **p09 l.32–33**: a match guard (`if r > 1`) with a `_` fallback. I read only the first matching arm.
- **p09 l.34**: the units of `$size`. I assumed bytes.
- **p10 l.16**: `apply` falls through to `a * b` for any operator other than `+` or `-`. Nothing in the program rejects an unknown operator, and I did not test that case.
- **p10 l.35**: the underflow in `eval("9 +")` comes from the second `take` in `apply`, not from the `+`.
- **p10 l.36–38**: a `catch |e|` followed by an indented block. The block's last value `0` is the result.
- **p11 l.26**: `for t in tasks` on an owned collection. I read it as non-consuming, because line 32 still uses `tasks`.
- **p11 l.29**: `Text?` and `Text("...")`. I assumed `Text` has a `.len` that counts 8 characters.
- **p12 l.27, l.29**: I put the writes at lines 28 and 30, not on the loop and binding lines 27 and 29, for question 2.
- **p12 l.14**: `0..players.len` is an exclusive range.
- **r03 l.14**: the missing `@` is inferred from the consistent use of `@` on mutating methods elsewhere. Nothing in the program states the rule.
- **r04 l.14**: the rejection depends on borrows ending at last use, which is inferred from p01.

### Overall

**6/10.** The core sigils are consistent and easy to recognize: `&` for read, `@` for write, `<` for move, `+` for copy, `*` for shared handle. The "exactly one line" rejections were also fairly clear once the borrow rules were understood. The rating drops because:

- `!`, `?` and `@` each mean several things depending on position (`!` is NOT, propagate, or a fallible type; `?` is an optional type, propagate `none`, or a `??` operand).
- The mutation rules are split in an unobvious way. A bare name passes implicitly to a `&` parameter. Mutating methods need `@`, but field assignments do not. `sub` does not mean "mutates."
- Several printed-output formats (optional values, `none`, error values, Vec) are never shown, so some answers are necessarily guesses.
- The drop and move semantics (`<`, `+`, `*`, `drop`) only became clear after reading several programs, and the first guesses missed most of them.
