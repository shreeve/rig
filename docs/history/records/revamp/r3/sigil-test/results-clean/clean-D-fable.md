# Rig: reading cold

## First guesses

Written after reading only p01, p02 and p03, before opening questions.md.

**Prefix symbols**

- `&` before a name or type (`&Item`, `&Vec[Item]`, `&items[0]`, `&items`, `&top`, `&Entry?`): a shared, read-only borrow. Functions taking `&T` only read. Passing a plain variable where `&T` is expected (`value(items)`, `report(ann)`) seems to borrow implicitly.
- `@` before a name or type (`@Item`, `@Vec[Entry]`, `@items.push(...)`, `@items[1]`, `@ws.next()`, `@from`): an exclusive, writable borrow. Mutating method calls must be written `@x.method()`, and a writable parameter is passed as `@x`.
- `!` before an expression (`!in_stock(it)`, `!(it.qty > 3)`, `!bob.frozen`): logical not.

**Postfix symbols**

- `?` after a type (`Int?`, `Entry?`): optional type, with `none` as the empty value.
- `!` after a return type (`-> Int!`) or after a `sub` signature (`sub transfer(...)!`): the function may fail with an error value instead of returning.
- `!` after a call expression (`withdraw(@from, n)!`): if the call failed, pass the failure up to the caller, otherwise unwrap the value.
- `??` between two expressions: default value when the left side is `none`.
- `catch` after a failing call: handle the failure, either with a plain fallback (`catch 0`) or a handler taking the error (`catch |e| print(...)`).
- `as` after a condition (`if find(...) as i`, `while @ws.next() as w`): test an optional, and if present bind its contents to a new name in the block.
- `if` after a statement (`return i if ...`): trailing condition, statement runs only when the condition holds.

**Keywords I did not recognize**

- `fun`: a function that returns a value, probably pure or at least value-producing.
- `sub`: a procedure run for its effects, no return value.
- `struct`: record type with named fields, built with `Item(name: ..., qty: ...)`.
- `error Bank` followed by indented names: declares a set of error values, referred to as `Bank.frozen`.
- `use std.text`: imports a module, called as `text.words(...)`.
- `none`: the empty optional.
- `and`, `or`: boolean operators spelled as words.
- `Vec[T]`, `Vec()`: growable list type and its constructor, with `.push`, `.len`, indexing `[i]`.
- `.next()` on the result of `text.words(...)`: an iterator yielding `String?`.

## Answers

### p01 — inventory

1. Line 23 prints `32` (4×3 + 0×1 + 2×10). High.
2. Line 25 prints `bolt 4`. High.
3. `items` may be modified on lines 20, 21, 22 (push through `@items`) and 26 (handed to `restock` for writing as `@items[1]`). Line 19 creates it; lines 23, 24, 28, 33 only read it. High.
4. Line 32 runs once, printing `low: gear` (bolt has 4, nut has 5 after restock, gear has 2). Line 33 prints `37 0`. High.

### p02 — word counter

1. No. `find` takes `entries: &Vec[Entry]`, a read-only borrow, so it cannot modify it. High.
2. Line 16 (`entries[i].count += 1`) and line 18 (`@entries.push(...)`). Line 15 only reads. High.
3. Line 35 prints `top: cat 2`. Counts are the 3, cat 2, others 1. The only entry with count not 1 and word not "the" is cat. High.
4. Line 36 prints `6 3 -1`. Six distinct words, "dog" is at index 3, "cow" is absent. High.

### p03 — bank ledger

1. After line 27: ann 70, bob 50. High.
2. Line 28 prints `failed: insufficient` (bob has 50, needs 80). No balance changes, because `withdraw` returns before subtracting and `to.balance += n` is never reached. High on behaviour, medium on the exact spelling of the error (could print as `Bank.insufficient`).
3. The trailing `!` on line 17 passes a failure on to the caller. High.
4. Lines 33–35 print:
   ```
   ann 70
   bob 45
   ```
   `!bob.frozen` is false, so `report(ann)` runs and prints `ann 70`, returns 70, and `70 != 70` is false, so "check ann" is not printed. Line 35 prints `bob 45` (50 minus the 5 withdrawn on line 29). High.

### p04 — job queue

1. Line 26 removes the first job from `q.jobs` and hands it to `job`. `q` shrinks by one. High.
2. The loop continues while `q` is not empty, that is while `q.jobs.len != 0`. High.
3. Line 31 prints, in order:
   ```
   ran 1 5
   ran 3 1
   ran 4 0
   ```
   Job 2 (cost 7) exceeds the remaining budget of 5 and is skipped. High.
4. Line 33 prints `2 0 0 false`. High.

### p05 — expression parser

1. `digit` returns `none` when the byte is not an ASCII digit. High.
2. Yes. `pos` is passed as `@pos`, and `number` advances it past the digits it consumed, stopping at the `+` (byte 43) or the end of the string. High.
3. Line 35 prints `-1 -2`. `"4+x"` fails with `Parse.bad` at the `x`. `"5++6"` fails with `Parse.empty` because the second call to `number` starts on a `+` and consumes nothing. High.
4. Line 36 prints `700 none 0`. `lead("7up")` gives 7×100. `lead("up7")` hits a non-digit and the `?` on line 31 returns `none`. `lead("")` is `none`, replaced by 0. Medium, because I am guessing how an empty optional is printed.

### p06 — binary tree

1. Line 33 (`insert(@root, k)`, repeated across the loop) and line 38 (`insert(@root, 45)`). Line 31 creates it. Lines 35, 36, 37, 39 only read. High.
2. `walk` cannot modify `root` (received as `&Box[Node]?`). It can modify `keys` (received as `@Vec[Int]`). High.
3. Line 36 prints `[20, 30, 40, 50, 70] 210`. Medium on the exact list formatting, high on the values.
4. Yes, line 38 runs because 45 is not in the tree. Line 39 prints `255 true`. High.

### p07 — shared configuration

1. Line 19 prints `2 2`. High.
2. No. Line 20 gives up `base`'s own handle, but `web` and `db` still hold handles to the same configuration, so nothing is released and nothing is printed. High.
3. Line 25 (`<web`). Line 23 replaced `db`'s handle with `debug`, so `web` held the last handle to "base". Dropping `web` releases it and prints `released base`. High.
4. `db`. Line 28 moves it into `running` with `<db`, so the name is dead afterwards. High.

### p08 — files

1. Line 23 prints `2 3`. High.
2. No. Line 21 built `backup` from a copy of `log.lines` (`+log.lines`), so line 22 appends only to `backup`. High.
3. `log`. It is moved into `archive` by `<log` on line 24. High.
4. Output from line 24 to the end:
   ```
   archive app.log 2
   close app.log
   after archive
   close tmp
   end 3
   close app.bak
   ```
   `archive` owns `f` and drops it on return, printing `close app.log`. Line 27 drops `tmp` immediately. `backup` is dropped when `main` ends. High on the sequence, medium on whether the final `close app.bak` is considered part of the program's output.

### p09 — shapes

1. Yes. Line 28 lends `shapes[1]` for writing, and `grow` changes the rect to `w = 5`, `h = 8`. High.
2. Lines 29–30 print:
   ```
   12
   40
   0
   ```
   High.
3. Line 32 prints `big circle 2`. High.
4. Line 34 prints `400 false`. `Pixel` is four `U8` fields, so 4 bytes; `area(dot)` is 0. High on `false`, medium on 400 (assumes `$size` is byte size with no padding).

### p10 — stack calculator

1. Line 8 pops the last element off `stack`, shrinking it by one, and binds the popped value to `x` if there was one. High.
2. A failure propagation. If `take` fails, `apply` returns that failure. High.
3. Line 33 prints `14`. Line 34 prints `2` (5 − (1 + 2)). High.
4. Line 35 prints `-1 -2`. `"9 +"` underflows on the second `take`. `"1 2"` leaves 1 on the stack after taking 2, so `Calc.leftover`. Line 39 prints `6`; `"8 2 -"` succeeds, so the handler on lines 36–38 never runs. High.

### p11 — task list

1. `none`. `postpone` only adds when the optional holds a value, and `tasks[1].due` was `none`. High.
2. Line 28 prints, in order:
   ```
   rent -4
   call -1
   taxes 20
   ```
   High.
3. Line 31 prints `2 8`. Two tasks are not done, and "bring id" has 8 characters. High.
4. Yes, line 32 pops the last task (taxes) off `tasks`, and the block prints `dropped taxes 25`. Line 34 prints `2`. High.

### p12 — game

1. No. `+players` makes an independent copy, so later changes to `players` do not affect `start`. High.
2. Lines 20, 21 (push), 27 (`for p in @players` lends each player for writing), 28 (`bump(@p.score, ...)` writes through that loan), 29 (`target = @players[...]` takes a writable loan) and 30 (`target.lives -= 1` writes through it). Line 19 creates it; line 22 copies it. High.
3. `done` is true when neither player is alive, that is when both have `lives <= 0`. High.
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Rounds: round 1 both score 10, ben loses a life (0). Round 2 ana 30, ana loses a life (1). Round 3 ana 60, ben already dead. Round 4 ana 100, ana loses her last life, both dead. High.

### Rejected programs

- **r01, line 11.** `charge` receives `a: &Account`, a read-only borrow, and tries to write `a.balance -= n` through it. High.
- **r02, line 18.** `r` was moved into `archive` on line 16 by `<r`, and line 18 reads `r.pages.len` after the move. High.
- **r03, line 14.** `cart.items.pop()` mutates the vector but is not written with `@`. The language requires `@cart.items.pop()`, as every other `pop`/`push` in the corpus is. High.
- **r04, line 14.** `top = &list[1]` holds a read-only loan on `list` that is still used on line 15, and line 14 pushes to `list` through `@list` while that loan is live. Medium on whether the compiler reports it at line 14 (the conflicting write) or line 15 (the later use); I choose 14 as the line that violates the loan.

## Revised meanings

- `&x` / `&T`: shared, read-only borrow. Confirmed. Also usable on an optional scrutinee (`if &note as n`) to bind the contents by shared reference, and omitted at call sites where the parameter type already says `&T`.
- `@x` / `@T`: exclusive, writable borrow. Confirmed. Also used on `self` in methods (`sub add(@self, ...)`), on a loop source (`for p in @players`) to lend each element for writing, and on a match or `if ... as` scrutinee (`match @s`, `if @slot as n`) to bind the contents writably.
- `!expr` prefix: logical not. Confirmed.
- `T?` postfix: optional type. Confirmed.
- `T!` postfix on a return type or `sub` signature: may fail. Confirmed.
- `call!` postfix: propagate failure. Confirmed.
- `expr?` postfix on an optional expression (`digit(s[0])?`, `due?`): new. If `none`, return `none` from the enclosing function, otherwise unwrap. I had only seen `?` on types in the first three files.
- `a ?? b`: default for `none`. Confirmed. The right side can be a `return` (`?? return Parse.bad`).
- `catch`: handle a failure with a value, a one-line handler, or an indented block whose last expression is the result. Confirmed and extended.
- `*Config(...)` / `*T`: new. Creates a shared, reference-counted handle to a value, released when the last handle goes away.
- `+x` prefix: new. Makes an independent copy. For a `*T` handle it adds another handle to the same object; for a `Vec` or struct it deep-copies.
- `<x` prefix: new. Moves the value out of the name, consuming it. As a call argument it transfers ownership; as a bare statement it drops the value right there. The name is unusable afterwards.
- `drop(@self)` inside a struct: destructor, runs when the owning value is dropped or moved into oblivion.
- `enum` with payload cases, `match`, `.case(bindings) =>`, `_`, case guards `if cond`, and `pass` as an empty arm: ordinary pattern matching. A match on `@s` lets the arm bindings be assigned to.
- `a if cond else b`: conditional expression, including in argument position.
- `0..n`: half-open range for `for`.
- `$size(T)`: compile-time size of a type in bytes.
- `continue`: as usual.
- `Box[T]`: owned heap box, created with `Box(value)`, with implicit dereference through `.field`.
- `Text` versus `String`: `Text` appears once (p11) as an owned string with `.len`; I treat it as a string type alongside `String`.

First guesses that were wrong or incomplete: I had `?` only as a type suffix, missing its postfix-on-expression propagation role. I guessed `fun` might be pure, but `fun report` in p03 prints, so `fun` just means "returns a value". I did not anticipate `*`, `+`, `<` as ownership operators at all. Everything else in the first guesses held.

## Where I hesitated

- **p05 line 12, `start = pos` with `pos: @Int`.** Could alias the borrow or copy the integer. Only copying makes `pos == start` on line 18 meaningful, so it copies, but the text does not say so.
- **p05 line 15, `?? return Parse.bad`.** A `return` as the right operand of `??` reads oddly. It parses as "if `none`, return from `number` with the error".
- **p06 line 8, `insert(@n.left if key < n.key else @n.right, key)`.** Easy to misread the trailing `if` as a statement condition applied to the whole `insert` call. It is a conditional expression selecting the first argument.
- **p07 lines 20, 25, 30, `<base` on its own.** Looks like a stray comparison. It is a move-and-drop statement. Likewise `+base` looks like unary plus and `*Config(...)` looks like a dereference or multiplication.
- **p07 line 23, `db.config = +debug`.** Whether the old handle is released by assignment matters for which line prints `released base`. I assumed assignment drops the previous handle, which is what makes line 25 the trigger.
- **p08 and r02, `archive(<log)`.** Whether `archive` drops its parameter at return (printing `close`) or hands it back. Owned parameter plus destructor means it drops at return.
- **p09 line 19, `match @s` with `r += by` in an arm.** Assigning to a pattern binding only makes sense if the binding is a writable reference into the enum. The `@` on the scrutinee signals that.
- **p11 line 30, `if &note as n`.** The `&` on the scrutinee rather than on `note` itself was new; I read it as "borrow the contents shared".
- **p12 line 28, `bump(@p.score, ...) if alive(p)`.** `p` is a writable loan from `for p in @players`, yet `alive` wants `&Player`. Implicit reborrow down to shared seems to be allowed, consistent with `value(items)` in p01.
- **Printing of `none` and of a `Vec`.** No example in the corpus shows either, so `none` and `[20, 30, 40, 50, 70]` are guesses.
- **r04.** Which line the compiler blames for a write during a live loan, the write (14) or the later use (15), is not determinable from the corpus.
- **`$size(Pixel)`.** Assumes no padding for four single-byte fields.

## Overall

**Rating: 7/10.**

The borrowing story is unusually legible: `&` for read, `@` for write, at both the declaration and every use site, so the modification questions can be answered by scanning for `@`. The `?`/`!` pairing on types and expressions is consistent once seen, and `as` bindings plus `catch` handlers read naturally. Indentation-based blocks and trailing `if` keep programs short.

What cost points: the three ownership prefixes `*`, `+` and `<` are unguessable from the first three programs and visually collide with arithmetic and comparison. `<x` as a standalone statement in particular reads as a syntax error. The `?` suffix doing double duty on types and expressions, `return` appearing as an operand of `??`, and conditional expressions in argument position are all terse enough to misparse on a first read. Finally, the corpus never shows how `none` or a list is printed, so exact-output answers for those cases rest on assumption.
