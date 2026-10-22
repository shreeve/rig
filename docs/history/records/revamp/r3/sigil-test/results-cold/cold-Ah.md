# Cold reading of Rig sigils: answers

## Conditions

Before this task started, the repository's AGENTS.md was loaded into my context. It contains a table of sigils (`<x` move, `?x` / `?T` lend to read / read view, `!x` / `!T` lend to write / write view, `+x` clone, `-x` drop, `*x` shared, `~x` weak, `expr!` / `T!` propagate failure / fallible type, `expr?` / `T?` propagate none / optional type). So this reading is not fully cold. Where my first guesses match that table, the match may come from having seen it, not from the programs. I have tried to mark that below where it matters. I did not read any other file in the repository.

## First guesses

Written after reading p01.rig, p02.rig and p03.rig only, before reading questions.md.

**Prefix symbols (directly before a name or type)**

- `?` before a type (`it: ?Item`, `items: ?Vec[Item]`, `best: ?Entry?`, `a: ?Account`): a read-only view of the value. The callee can look but not change it.
- `?` before a name at a call or loop (`?items[0]`, `for it in ?items`, `report(?top)`): a read-only lend at that site, matching the `?` in the parameter.
- `!` before a type (`it: !Item`, `entries: !Vec[Entry]`, `from: !Account`): a write view. The callee may change the value.
- `!` before a name at a call (`!items.push(...)`, `restock(!items[1], 5)`, `add(!entries, w)`, `withdraw(!from, n)`): a write lend at the call site. It must match the `!` in the parameter. `!items.push(...)` looks like a mutating method called through a write lend.
- `-` before a number (`-1` in `?? -1`): a negative literal. No other prefix `-`, `+`, `*`, `~` or `<` appears in these three programs, so I have no guesses for them.

**Postfix symbols (directly after an expression or type)**

- `?` after a type (`Int?`, `Entry?`, the trailing `?` in `?Entry?`): an optional type. The value may be `none`.
- `!` after a type (`-> Int!`, `sub transfer(...)!`): a fallible type. The function can fail with an error.
- `!` after a call (`withdraw(!from, n)!`, `transfer(!ann, !bob, 30)!`): propagate failure. If the call fails, the enclosing function fails with the same error.
- `??` (binary, `find(entries, "dog") ?? -1`): if the left side is `none`, use the right side. A default value.

**Keywords I do not recognize**

- `struct`: a record type with named fields. Clear from the shape.
- `fun` and `sub`: `fun` has `-> Type` and returns a value. `sub` has no return type and is a procedure. `sub` can also be fallible (`)!`).
- `error Bank`, with indented names underneath: an error type with named cases, read as `Bank.insufficient`.
- `use std.text`: import a standard library module.
- `as` in `if find(...) as i` and `while (!ws).next() as w` and `if best as e`: bind the value if it is present (unwrap an optional in the branch).
- `catch |e| expr` and `catch 0`: handle a failure. `|e|` binds the error. `catch 0` supplies a fallback value.
- `return X if cond`: a conditional return, placed after the value.
- `none`: the empty optional value.
- `not`, `and`, `or`: boolean operators.
- `print`, `Vec`, `Vec()`, `Item(name: ..., qty: ...)`: a function, a generic type, a constructor, and a named-argument constructor. I have no guess beyond that.
- `text.words(...)` and `.next()`: a method on a module and a method on an iterator. `.next()` may return an optional.
- `:` with `=` as in `items: Vec[Item] = Vec()` (explicit type) versus `sum = 0` (inferred type). `=` also assigns.
- `Bank.frozen`: an error case. A dotted name.

## Answers

Confidence: high, medium or low. Line numbers are in the named program.

### p01 — inventory

1. `32`. (high)
2. `bolt 4`. (high)
3. Lines 20, 21 and 22 (`!items.push(...)`) and line 26 (`restock(!items[1], 5)`). Line 19 creates `items`; it does not modify it. (high)
4. Line 32 runs once, for `gear` (qty 2). Line 33 prints `37 0`. (high)

### p02 — word counter

1. No. `find` takes `entries` as `?Vec[Entry]`, a read view, and nothing in it is written. (high)
2. Line 16 (`entries[i].count += 1`) and line 18 (`!entries.push(...)`). Line 15 only reads. (high)
3. `top: cat 2`. Only `cat` has a count other than 1 and is not `the`. (medium: this assumes `top = e`, which assigns a read view into an owned `Entry?`, copies the entry; the program does not say so)
4. `6 3 -1`. (high)

### p03 — bank ledger

1. `ann` 70, `bob` 50. (high)
2. Line 28 prints `failed: insufficient`. No balance changes: `withdraw` fails before its subtraction, and the `!` on line 17 stops `transfer` before `to.balance += n`. (high for no change; medium for the exact text of the error)
3. It passes the failure on: `!` after a call is propagate-failure. (high)
4. Lines 33 to 35 print `ann 70` and `bob 45`. Line 33 calls `report(ann)` because `not bob.frozen` is false and `or` must evaluate its right side; the result 70 makes the test false, so `check ann` is not printed. (medium: depends on `not` binding tighter than `or`; the other parse also makes the test false, but it would skip the `ann 70` line)

Whole program output, for reference: `failed: insufficient`, `45`, `failed: frozen`, `ann 70`, `bob 45`.

### p04 — job queue

1. Line 26 takes a write lend of `q`, calls `next`, which removes the first job and returns it. So `q` loses its first job (job 1). (high)
2. While `q` has at least one job (`not q.is_empty()`). (high)
3. `ran 1 5`, `ran 3 1`, `ran 4 0`, in that order. Job 2 costs 7 against a budget of 5, so it goes to `skipped` and is not run. (high)
4. `2 0 0 false`. (high)

### p05 — expression parser

1. When `b` is not an ASCII digit (`text.is_digit(b)` is false). (high)
2. Yes. `number` takes `!Int`, a write view, and advances `pos` to the `+` (or the end) where it stops. `sum` then adds 1 to skip the separator. (high)
3. `-1 -2`. `sum("4+x")` fails with `Parse.bad`; `sum("5++6")` fails with `Parse.empty`. (high)
4. `700 none 0`. `lead("7up")` is 700. `lead("up7")` propagates none. `lead("")` is none, and `?? 0` gives 0. (high for 700 and 0; medium for the printed form `none`)

### p06 — binary tree

1. Lines 33 and 38. Line 31 declares `root`. (high)
2. `walk` cannot modify `root` (`slot` is `?Box[Node]?`, a read view). It can modify `keys` (`out: !Vec[Int]`, which it pushes into). (high)
3. `[20, 30, 40, 50, 70] 210`. The keys come out in order, and the sum is 50+30+70+20+40. (high for the values; medium for the printed format of a Vec)
4. Yes, line 38 runs, because 45 is not in the tree. Line 39 prints `255 true`. (high)

### p07 — shared configuration

1. `2 2`. (high)
2. No. Three handles to `base` exist (`base`, `web.config`, `db.config`). Line 20 drops only the variable's handle, so two remain. (high)
3. Line 25, `<web`. Line 23 already dropped `db`'s handle to `base`, so `web`'s handle is the last one. Dropping `web` on line 25 releases it, which runs `Config`'s `drop` and prints `released base`. (high)
4. `db`. Line 28 moves it into `running`. (high)

Whole program output, for reference, from line 19 on: `2 2`, `dropped base handle`, `9 2`, `released base`, `dropped web`, `1 9`, `end of main`, then `released debug` when `running` goes out of scope at the end of `main`.

### p08 — files

1. `2 3`. (high)
2. No. `+log.lines` clones the vector, so `backup` has its own copy. (high)
3. `log`. Line 24, `archive(<log)`, moves it. (high)
4. `archive app.log 2`, `close app.log`, `after archive`, `close tmp`, `end 3`, `close app.bak`. The `close` lines come from `drop(!self)`, which runs when a value is released. (high)

### p09 — shapes

1. Yes. `grow(!shapes[1], 2)` changes `shapes[1]` in place from `rect(3, 4)` to `rect(5, 8)`. `match !s` gives write views of the fields, so `w += by` and `h *= by` write to the vector element. (high)
2. `12`, `40`, `0`, one per line. (high)
3. `big circle 2`. (high)
4. `400 false`. `@size(Pixel)` is 4 bytes (four `U8` fields), times 100. (medium: I assumed `@size` gives bytes)

### p10 — stack calculator

1. `take` pops the top value off `stack` when there is one. When the stack is empty, `pop` gives none and `take` fails with `underflow`. (high)
2. Failure propagation. (high)
3. Line 33 prints `14`. Line 34 prints `2`. (high)
4. Line 35 prints `-1 -2`. Line 39 prints `6`. The `catch` block on lines 36 to 38 does not run. (high)

### p11 — task list

1. `none`. Line 24 postpones a task whose `due` is none, so nothing changes. (high)
2. `rent -4`, `call -1`, `taxes 20`. (high)
3. `2 8`. `open` is 2 (`call` and `taxes` are not done), and `"bring id".len` is 8. (medium: I took `Text` as a built-in string type, since the file does not declare it)
4. Yes. `(!tasks).pop()` removes the last task, `taxes`, so line 34 prints `2`. Line 33 prints `dropped taxes 25` before that. (high)

### p12 — game

1. No. `start = +players` on line 22 clones the vector. Later changes to `players` do not reach `start`. (high)
2. Lines 20 and 21 (`push`), 27 (`for p in !players` lends each element for writing), 28 (`bump(!p.score, ...)`), 29 (`target = !players[...]`), and 30 (`target.lives -= 1`). Line 19 creates `players`. (high)
3. `done` is true when neither player is alive (both have 0 lives). That first happens in round 4, after `ana` loses her last life on line 30. (high)
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. `ana` ends with score 100 and `ben` with 10. (high)

### r01–r04 (rejected)

- r01: line 11, `a.balance -= n` in `charge`. Parameter `a` is `?Account`, a read view, so it cannot be written. (high)
- r02: line 18, `r.pages.len`. `r` was moved into `archive` on line 16 (`archive(<r)`), so using it afterwards is a use after move. (high)
- r03: line 14, `cart.items.pop()`. `pop` changes `cart.items`, but the call has no write lend. Every other mutating call in these programs writes `!x.m()` or `(!x).m()`. (medium-high)
- r04: line 14, `!list.push(...)`. `top` (`?list[1]`) is a read view into `list` and is still used on line 15, so the write lend conflicts with a live view. (high)

## Revised meanings

- `?x` at a call, `?T` in a type: read lend and read view. The callee cannot write through it (r01). An unmarked name also passes to a read parameter (`value(items)`, `find(entries, w)`, `sum(root)`). The `?` is optional at read calls, but the `!` is required at write calls.
- `!x` at a call, `!T` in a type: write lend and write view. It is required at the call site of a write parameter (`restock(!items[1], 5)`, `insert(!root, k)`). It also appears in `if !slot as n`, `match !s` (write views of the fields), and `for p in !players`.
- `!x.m()` and `(!x).m()`: both lend `x` for writing before calling `m`. The parenthesised form is used when the call is part of a larger expression (`if (!stack).pop() as x`, `(!q).next()`).
- `+x`: clone. For a vector it copies the elements. For a shared handle it adds a handle to the same value.
- `<x`: move. As an argument (`archive(<log)`, `running.push(<db)`) it moves the value in. On its own (`<base`, `<tmp`) it moves the value out of the program and drops it now.
- `*T` and `*X(...)`: a shared, reference-counted value. Each `+` adds a handle, each move or drop removes one. When the last handle goes, the value's `drop(!self)` method runs.
- `drop(!self)`: a method that runs when the value is released, at scope end or on `<x`.
- `T!`, `sub ...)!`, `f(...)!`: a fallible type, a fallible sub, and propagate-failure. `catch |e| block` and `catch value` handle a failure. Errors are named cases, such as `Bank.frozen`.
- `T?`: an optional type. `none` is its empty value. `expr?` propagates none out of the enclosing function (`digit(s[0])? * 100`, `due? - today`).
- `a ?? b`: a default when the left side is none. `?? return X` returns `X` instead.
- `if x as y` and `while x as y`: bind the value of an optional when it is present.
- `match s` with `.variant(x) => ...` arms, `_` as the wildcard, `pass` as the empty body.
- `-1`: a negative literal. I saw no unary `-x` in these programs, so I have no evidence for `-x` as "drop now".
- `@size(T)`: a size intrinsic (bytes assumed).
- `a..b` in `for`: a range; I assumed the upper bound is excluded.
- `not`, `and`, `or`: boolean operators. `not` binds tighter than `or` and `and`, and looser than comparison (`not x > 3` is `not (x > 3)`).

First guesses that were wrong or incomplete:

1. I guessed that a `?` at a call must match the `?` in the parameter. Wrong: an unmarked name passes to a read parameter.
2. I did not guess the postfix `?` on an expression (propagate none). I first read `due?` in p11 as an optional type.
3. I did not guess the `??` form with `return` on the right.
4. I did not guess `!` on a `match` or `if ... as` binding (write view of a field or of the value inside an optional).
5. I did not guess that `(!x).m()` and `!x.m()` mean the same thing.
6. I did not guess `+` as clone of a vector or as a new handle to a shared value, or `*` as a shared constructor.
7. I did not guess `<x` as a move into an argument, or as a drop on a line of its own.
8. Right: `?T` and `!T` as views, `!x` at a call as a write lend, the trailing `!` after a call as propagate-failure, `?T`/`T?` as optional, `??` as default, `as` as unwrapping in a branch, `sub` as no-return, `struct`, `use`, `error` as named cases, `return X if c`.

## Where I hesitated

- p01 l.31 `if not it.qty > 3`: first read as `(not it.qty) > 3`. Resolved as `not (it.qty > 3)`.
- p02 l.15 `find(entries, w)`, where `entries` is itself a write view: I wondered whether it needed `!` or `?`. Resolved: an unmarked name passes to a read parameter.
- p02 l.34 `top = e`: `e` is a read view and `top` is owned. I assumed the assignment copies the entry. The program does not say so, so this is the least certain step in p02.
- p03 l.17 `withdraw(!from, n)!`: the last `!` first looked like a second write lend. Resolved as propagate-failure.
- p03 l.33 `not bob.frozen or report(ann) != 70`: unsure whether `not` covers the whole `or`. Chose the tighter reading; it decides whether `ann 70` is printed.
- p04 l.26 `job = (!q).next()`: the parentheses first looked like a grouping that does nothing. They are needed for a method call on a write lend used as a value.
- p05 l.15 `d = digit(s[pos]) ?? return Parse.bad`: I first read `return` as an ordinary default value. It is an early return on none.
- p05 l.31 `digit(s[0])? * 100`: the `?` looked like an optional type. It is propagate-none.
- p05 l.35 `catch -1, sum(...)`: the comma after the catch value, and the `-1`, took a second look.
- p06 l.7 `if !slot as n`: first read as "if not slot". It binds `n` as a write view.
- p06 l.8 `insert(!n.left if key < n.key else !n.right, key)`: a conditional that yields a write lend. Read it twice.
- p07 l.20 `<base`: at first I expected it to print `released base`. It only drops one of three handles.
- p07 l.25 `<web`: the line that finally releases `base`. The answer depends on line 23 having already dropped the other handle.
- p07 l.16 `*Config(...)`: first read as a dereference. It is a shared constructor.
- p08 l.11 `archive(f: File)`: the parameter has no marker, so it takes ownership. The `close app.log` line comes from the drop at the end of `archive`.
- p09 l.34 `@size(Pixel)`: an unknown intrinsic. I assumed bytes.
- p09 l.20 `r += by` inside `match !s`: at first I thought `r` was a copy. It writes through the view.
- p10 l.8 `if (!stack).pop() as x`: I first thought `pop` only peeks. It removes.
- p11 l.15 `due? - today`: the `?` looked like an optional type. It propagates none from a read view of an optional.
- p11 l.29 `Text?`: `Text` is never declared in the file. I assumed a built-in like `String`.
- p12 l.14 `0..players.len`: I assumed an exclusive upper bound.
- p12 l.29 `target = !players[round % 2]`: a write view of a chosen element, not a copy.

## Overall

**7 out of 10.** The core is small and regular. `?` means read, `!` means write, `<` moves, `+` clones, `*` is shared, and `!` after a call means propagate. Each one shows at the place where the effect happens, so I could follow ownership and mutation line by line. The notation costs me in four places:

- `?` and `!` are each used both before and after a name, and both before and after a type. Postfix `?` and `!` also appear as propagate. I had to work out each use from its position.
- Read markers are optional at a call, but write markers are required. I guessed the opposite for `?`.
- `(!x).m()` and `!x.m()` look like two spellings of one call, and I was not sure whether they are.
- Precedence of `not` against `or` and comparison, and the exact printed form of errors, `none`, `Vec` and `@size`, were not stated anywhere in the programs.
