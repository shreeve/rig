# Rig: first guesses, answers to the reading questions, and revised meanings

## First guesses
*(Written after reading only p01, p02 and p03, and not revised later.)*

**Prefix symbols**
- **`&` before a type** (`&Item`, `&Vec[Item]`): a read-only reference or borrow. The function can look at the value but not change it.
- **`&` before an expression** (`&items[0]`, `&items`, `&top`): takes a read-only borrow at the call or use site.
- **`@` before a type** (`@Item`, `@Account`): a mutable reference. The callee may write through it.
- **`@` before an expression** (`@items.push(...)`, `@from`, `@ws.next()`): explicitly lends the value for writing, either to a function or to a mutating method. It works as a visible marker that "this value may change here".
- **`!` before an expression** (`!in_stock(it)`, `!(it.qty > 3)`): logical not.
- **`-` before a number** (`-1`): ordinary negative number.

**Postfix symbols**
- **`?` after a type** (`Int?`, `Entry?`, `&Entry?`): optional. The value is either present or `none`.
- **`!` after a type** (`Int!`): the result may instead be an error (a result or error-union type).
- **`!` after a sub's parameter list** (`sub transfer(...)!`): the sub may fail. It has no value but can return an error.
- **`!` after a call** (`withdraw(@from, n)!`, `transfer(...)!`): propagate the error. If the call failed, the current function returns that error; otherwise you get the value, like `try` or Rust's `?`.

**Keywords and constructs**
- **`fun` / `sub`**: `fun` is a function that returns a value, probably pure. `sub` is a procedure with no return value that may mutate.
- **`struct`**: declares a record type with indented fields.
- **`error Bank` with indented names**: declares a set of error values (`Bank.frozen`, `Bank.insufficient`).
- **`use std.text`**: imports a module.
- **`none`**: the empty value of an optional.
- **`if x as name`** and **`while ... as name`**: unwrap an optional. If it is present, bind it to `name` and run the body.
- **`return x if cond`**: a guarded early return, with the condition written after the value.
- **`a ?? b`**: use `a` if it is present, otherwise the default `b`.
- **`expr catch value`** and **`expr catch |e| stmt`**: handle an error. Either substitute a value, or bind the error to `e` and run a handler.
- **`and` / `or`**: boolean operators.
- **Type and argument syntax**: `name: Type = ...` is a typed declaration. `Vec()` constructs an empty vector. `Item(name: ..., ...)` is a constructor with named fields.

## Answers

### p01: inventory
1. Line 23 prints `32` (12 + 0 + 20). **High**
2. Line 25 prints `bolt 4`. **High**
3. `items` may be modified on lines **20, 21, 22 and 26**. **High**
4. Line 32 runs **once** and prints `low: gear`. Line 33 prints `37 0`. **High**

### p02: word counter
1. **No.** `find` takes `&Vec[Entry]`, which is read-only. **High**
2. Lines **16** (`entries[i].count += 1`) and **18** (`@entries.push`). **High**
3. Line 35 prints `top: cat 2`. **High**
4. Line 36 prints `6 3 -1`. The six entries are the, cat, saw, dog, and, ran, and "dog" is at index 3. **High**

### p03: bank ledger
1. After line 27, ann has **70** and bob has **50**. **High**
2. Line 28 prints `failed: Bank.insufficient`. I'm unsure of the exact error format; it might print just `insufficient`. **No balance changes**, because `withdraw` returns before subtracting and `to.balance += n` is never reached. **High for the balances, low for the exact text**
3. The final `!` on line 17 **passes the failure on**. **High**
4. Lines 33–35 print `ann 70` (from `report(ann)` inside the condition) and then `bob 45`. `check ann` is not printed. **High**

### p04: job queue
1. Line 26 removes the first job from `q.jobs`, which mutates `q`, and returns it. **High**
2. The loop keeps going while `q` is not empty. **High**
3. Line 31 prints `ran 1 5`, then `ran 3 1`, then `ran 4 0`. **High**
4. Line 33 prints `2 0 0 false`. **High**

### p05: expression parser
1. `digit` returns `none` when byte `b` is not an ASCII digit character. **High**
2. **Yes.** `pos` is passed as `@pos`, and `number` advances it to the next `+` or to the end of the string. **High**
3. Line 35 prints `-1 -2`. `"4+x"` hits `Parse.bad`, and `"5++6"` hits `Parse.empty`. **High**
4. Line 36 prints `700 none 0`. I'm unsure how `none` prints. **Medium**

   (Line 34 prints `49`.)

### p06: binary tree
1. `root` may be modified on lines **33 and 38**. **High**
2. `walk` may **not** modify `root`, because that parameter is `&`. It **may** modify `keys`, because that parameter is `@`. **High**
3. Line 36 prints `[20, 30, 40, 50, 70] 210`. **High** for the values, **medium** for the list format.
4. **Yes**, line 38 runs, because 45 is not in the tree. Line 39 prints `255 true`. **High**

### p07: shared configuration
1. Line 19 prints `2 2`. **High**
2. **No.** `web` and `db` still hold handles to "base", so only `base`'s own handle is dropped. **High**
3. **Line 25** (`<web`). Line 23 already moved `db` to `debug`, so `web` held the last handle to "base". **High**
4. **`db`**, because it was moved into `running` on line 28. **High**

### p08: files
1. Line 23 prints `2 3`. **High**
2. **No.** `+log.lines` makes an independent copy. **High**
3. **`log`**, because it was moved into `archive` on line 24. **High**
4. Output from line 24 to the end, in order: **Medium-high** (depends on when values are dropped)
   ```
   archive app.log 2
   close app.log
   after archive
   close tmp
   end 3
   close app.bak
   ```

### p09: shapes
1. **Yes.** `shapes[1]` changes from `rect(w: 3, h: 4)` to `rect(w: 5, h: 8)`: `w` gets `+= 2` and `h` gets `*= 2`. **High**
2. Lines 29–30 print `12`, then `40`, then `0`. **High**
3. Line 32 prints `big circle 2`. **High**
4. Line 34 prints `400 false`. `$size(Pixel)` is 4 bytes. **High**

### p10: stack calculator
1. The last element is popped from `stack`, which mutates it. If there was one, it is bound to `x`. **High**
2. It is a **failure propagation**. **High**
3. Line 33 prints `14` and line 34 prints `2`. **High**
4. Line 35 prints `-1 -2`, and line 39 prints `6`. The handler on lines 37–38 does not run. **High**

### p11: task list
1. `tasks[1].due` is still **`none`**, because `postpone` does nothing for an empty optional. **High**
2. Line 28 prints `rent -4`, then `call -1`, then `taxes 20`. **High**
3. Line 31 prints `2 8`. **High**
4. **Yes.** Line 32 pops "taxes", and line 33 prints `dropped taxes 25`. Line 34 prints `2`. **High**

### p12: game
1. **No.** `+players` makes an independent copy. **Medium-high**
2. `players` may be modified on lines **20, 21, 27, 28, 29 and 30**. **Medium-high**
3. `done` is true when both players have 0 lives. **High**
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. **High**

### Rejected programs
- **r01, line 11:** `a.balance -= n` writes through `a: &Account`, which is a read-only borrow. **High**
- **r02, line 18:** it reads `r.pages.len` after `r` was moved away by `archive(<r)` on line 16. **High**
- **r03, line 14:** `cart.items.pop()` mutates `items` without the `@` marker; it should be `@cart.items.pop()`. **Medium-high**
- **r04, line 14:** it pushes to `list`, which may reallocate, while `top = &list[1]` is still borrowed and used on line 15. **Medium**. The compiler could instead flag the use on line 15.

## Revised meanings
- **`&`**: a read-only borrow. **Confirmed.** Passing a plain variable to a `&` parameter also seems to borrow it implicitly (`value(items)`, `walk(root, …)`, `contains(root, 45)`). An explicit `&` is optional at call sites.
- **`@`**: a mutable borrow, or "lent for writing". **Confirmed.** It is required at every point where a value may change through a call or method, including `@q.next()` and `@stack.pop()`. It is not needed for plain field assignment through an `@` parameter (`it.qty += n`). It also works in patterns: `match @s` and `if @due as d` give mutable bindings.
- **`!` prefix**: logical not. **Confirmed.**
- **`?` after a type**: optional. **Confirmed.** I had not seen the postfix `?` on an expression (`digit(s[0])? * 100`, `due? - today`). It means "if this is `none`, return `none` from the current function", which is the optional counterpart of `!`.
- **`!` after a type or sub**: may fail. **Confirmed.** **`!` after a call**: propagate the error. **Confirmed.**
- **`fun` vs `sub`: my first guess was partly wrong.** `fun` returns a value but is **not** necessarily pure: `fun next(@self)` and `fun take(stack: @Vec[Int])` mutate. `sub` has no return value.
- **New symbols:**
  - **`*Type` and `*Config(...)`**: a shared, reference-counted handle.
  - **`+x`**: copy or clone. On a `*` handle it adds a new reference to the same object. On an ordinary value (`+log.lines`, `+players`) it makes an independent deep copy.
  - **`<x`**: move out of `x` or give it up. As a statement it drops `x`; as an argument it transfers ownership. Afterwards `x` is unusable.
  - **`$size(T)`**: a compile-time built-in.
- **New keywords:**
  - **`drop(@self)`**: a destructor.
  - **`enum` with variants plus `match` / `.variant(bindings) => ...`**: tagged unions and pattern matching, with `if` guards and a `_` wildcard.
  - **`pass`**: does nothing.
  - **`x if c else y`**: a conditional expression.
  - **`..`**: a range.
  - **`?? return ...`**: early return as the fallback for `??`.
- **The rest of my first guesses held up:** `as`, `??`, `catch` and `error`. `catch |e|` can also take an indented block whose last expression is the value.

## Where I hesitated
- **p03 line 16, `sub transfer(...)!`:** a `!` after a parameter list with no return type looked odd at first. I settled on "a sub that can fail".
- **p03 line 28, how the error `e` prints:** I still don't know whether it is `Bank.insufficient` or `insufficient`.
- **p04 lines 14–15, `fun next(@self)` with `@self.jobs.remove(0)`:** this broke my guess that `fun` is pure.
- **p05 line 12, `start = pos` with `pos: @Int`:** I had to check whether `start` copies the integer or aliases it. I concluded it copies, otherwise `pos == start` would always be true.
- **p05 line 15, `?? return Parse.bad`:** I re-read this; `return` is used as an expression on the right of `??`.
- **p05 line 31, `digit(s[0])? * 100`:** at first I read `?` as part of `?*` or as a type. It is propagation of `none`.
- **p06 line 8, `insert(@n.left if key < n.key else @n.right, key)`:** I had to parse the inline conditional producing a mutable borrow.
- **p06 lines 35/37 vs 36/39:** `root` is passed sometimes with `&` and sometimes bare. I checked whether a bare `root` meant a move. It must be an implicit read borrow, because `root` is used again afterwards.
- **p07 symbols `*`, `+` and `<`:** this was the hardest program. At first I took `<base` for a comparison fragment, then realised it is a drop or release. I also had to work out that line 23 dropping `db`'s reference to base is what leaves `web` as the last holder.
- **p08 / p12, `+` on a non-`*` value:** I briefly wondered whether `+log.lines` shares the vector like `+base` does. Line 22 must not affect `log`, so it is a copy, and I applied the same reading to `+players`.
- **p08 line 27, `<tmp` alone on a line:** I confirmed it is an explicit drop, and I assumed `backup` is dropped at the end of `main`.
- **p09 line 34, `$size`:** an unfamiliar sigil. I guessed it is a compile-time built-in and computed 4 bytes.
- **p11 line 29, `Text` vs `String`:** I'm not sure what the difference is. I assumed `.len` is 8 either way.
- **p12 line 29, `target = @players[round % 2]`:** I checked that `target` is a mutable alias into `players`, so line 30 modifies `players`.
- **r03 / r04:** I had to decide which line the compiler would blame. For r04 the push on line 14 conflicts with the borrow in `top`, but it could be reported on line 15.

## Overall
**7/10.** The core sigils are easy to read once you have seen two examples: `&` means read, `@` means write, `?` means optional, and `!` means may fail. The `@` at every mutation site makes the "where is X modified" questions very easy, which is a real plus. The ownership sigils `*`, `+` and `<` cannot be guessed cold. `+` means "share" on handles but "deep copy" on values, and `<` looks like a comparison operator. `!` has three roles (not, failure type, propagate) and `?` has two, which needs care when reading. The implicit `&` at some call sites is also inconsistent with the explicit ones. Indentation-based blocks and postfix `if` read naturally.
