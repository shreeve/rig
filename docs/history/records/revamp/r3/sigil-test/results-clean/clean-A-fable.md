# Rig reading report

## First guesses

Written after reading only p01, p02 and p03.

**Prefix symbols**

- `?` before a type (`?Item`, `?Vec[Item]`, `?Entry?`): read-only borrowed parameter. Before an expression (`?items`, `?items[0]`, `?top`): take a read-only reference or view of the value.
- `!` before a type (`!Item`, `!Vec[Entry]`, `!Account`): mutable borrowed parameter. Before an expression (`!items.push(...)`, `!entries`, `!from`, `(!ws).next()`): lend the value for writing, and on a method call mark the call as mutating its receiver.

**Postfix symbols**

- `?` after a type (`Int?`, `Entry?`): optional type, holding a value or `none`.
- `!` after a type (`Int!`) or after a `sub` signature (`sub transfer(...)!`): the function may fail with an error value instead of returning normally.
- `!` after a call (`withdraw(!from, n)!`, `transfer(!ann, !bob, 30)!`): propagate the failure to the caller, like Rust's `?`.
- `??` between expressions: default used when the left side is `none`.

**Keywords I did not recognize**

- `fun`: function returning a value. `sub`: procedure that returns nothing and exists for side effects.
- `struct`: record type. `error Bank` with indented names: declares an error type with variants, referred to as `Bank.frozen`.
- `use std.text`: import a module.
- `none`: the empty optional.
- `as` in `if find(entries, w) as i`: unwrap an optional and bind the value if present.
- `catch |e| expr` and `catch 0`: handle a failed call with a handler receiving the error, or substitute a default.
- `return X if cond`: postfix conditional return. `not`, `and`, `or`: boolean operators, with `not` binding looser than comparisons.
- `Vec()`, `.len`, `.push`: growable vector constructor, length and append.

## Answers

### p01 — inventory

1. Line 23 prints `32`. Confidence: high.
2. Line 25 prints `bolt 4`. Confidence: high.
3. Lines 20, 21, 22 (pushes) and 26 (`restock(!items[1], 5)` writes through a mutable borrow). Line 19 only initializes. Lines 24 and 28 are read-only borrows. Confidence: high.
4. Line 32 runs once (for `gear`, since `not it.qty > 3` is `not (it.qty > 3)`). Line 33 prints `37 0`. Confidence: high.

### p02 — word counter

1. No. `find` takes `entries: ?Vec[Entry]`, a read-only borrow, so it cannot modify it. Passing a `!Vec` where a `?Vec` is expected is an implicit read-only reborrow. Confidence: high.
2. Line 16 (`entries[i].count += 1`) and line 18 (`!entries.push(...)`). Line 15 is a read. Confidence: high.
3. Line 35 prints `top: cat 2`. Confidence: high.
4. Line 36 prints `6 3 -1`. Confidence: high.

### p03 — bank ledger

1. After line 27, ann has 70 and bob has 50. Confidence: high.
2. Line 28 prints `failed: insufficient`. No balance changes, because `withdraw` returns the error before the subtraction, and the propagation on line 17 skips line 18. Confidence: high for behavior, low for the exact text of the error. It might print as `failed: Bank.insufficient`.
3. It passes a failure on (error propagation). Confidence: high.
4. Lines 33 to 35 print:

```
ann 70
bob 45
```

Line 33 evaluates `not bob.frozen` as false, so `or` evaluates `report(ann)`, which prints `ann 70` and returns 70. The comparison fails, so `check ann` is not printed. Confidence: high.

### p04 — job queue

1. Line 26 calls `next` with a mutable borrow of `q`, which removes and returns the first job from `q.jobs`. Confidence: high.
2. The loop keeps going while `q.jobs` is non-empty. Confidence: high.
3. Line 31 prints, in order:

```
ran 1 5
ran 3 1
ran 4 0
```

Confidence: high.

4. Line 33 prints `2 0 0 false`. Confidence: high.

### p05 — expression parser

1. `digit` returns `none` when `b` is not an ASCII digit character. Confidence: high.
2. Yes. `pos` is passed as a write borrow and `number` advances it past the digits it consumed, to the index of the next `+` (byte 43) or the end of the string. Confidence: high.
3. Line 35 prints `-1 -2`. `sum("4+x")` fails with `Parse.bad` at the `x`, and `sum("5++6")` fails with `Parse.empty` at the second `+`. Confidence: high.
4. Line 36 prints `700 none 0`. Confidence: medium. The values are certain, but the printed form of an empty optional is a guess.

### p06 — binary tree

1. Line 33 (`insert(!root, k)` inside the loop) and line 38 (`insert(!root, 45)`). Line 31 only initializes. Lines 35, 36, 37 and 39 are read-only. Confidence: high.
2. `walk` cannot modify `root`, because `slot` is `?Box[Node]?`. It may modify `keys`, because `out` is `!Vec[Int]`. Confidence: high.
3. Line 36 prints `[20, 30, 40, 50, 70] 210`. Confidence: medium. The vector formatting is a guess.
4. Line 38 runs, because 45 is not in the tree. Line 39 prints `255 true`. Confidence: high.

### p07 — shared configuration

1. Line 19 prints `2 2`. Confidence: high.
2. No. Line 20 releases only the `base` variable's handle. `web.config` and `db.config` still share the same configuration, so `released base` is not printed there. Confidence: high.
3. Line 25 (`<web`). Line 23 replaced `db`'s handle with `debug`, so `web` held the last handle to `base`. Dropping `web` drops that handle and runs the destructor. Confidence: high.
4. `db` can no longer be used after line 28, because `<db` moved it into `running`. Confidence: high.

### p08 — files

1. Line 23 prints `2 3`. Confidence: high.
2. No. Line 21 built `backup` from a copy of `log.lines`, so line 22 appends only to the copy. Confidence: high.
3. `log` can no longer be used after line 24, because `<log` moved it into `archive`. Confidence: high.
4. Output from line 24 to the end:

```
archive app.log 2
close app.log
after archive
close tmp
end 3
close app.bak
```

`archive` owns `f` by value, so `log` is destroyed when `archive` returns. The standalone `<tmp` destroys `tmp` immediately. `backup` is destroyed when `main` ends. Confidence: medium. The ordering of `close app.bak` after `end 3` depends on scope-exit drop timing, which is the common design.

### p09 — shapes

1. Yes. `grow(!shapes[1], 2)` writes into the `rect` payload in place. `w` becomes 5 and `h` becomes 8, so `shapes[1]` is `rect(w: 5, h: 8)`. Confidence: high.
2. Lines 29 and 30 print:

```
12
40
0
```

Confidence: high.

3. Line 32 prints `big circle 2`. Confidence: high.
4. Line 34 prints `400 false`. `Pixel` is four one-byte fields, so `@size(Pixel)` is 4. Confidence: medium. The size assumes no padding, which is natural for four `U8` fields.

### p10 — stack calculator

1. Line 8 pops the last element from `stack` through a write borrow. If the stack is non-empty it shrinks by one and the value is bound to `x`. If it is empty, `pop` returns `none`, the stack is unchanged, and the function fails with `Calc.underflow`. Confidence: high.
2. Failure propagation. The `!` inside the parentheses is the write borrow. The trailing `!` passes a failure from `take` on to the caller of `apply`. Confidence: high.
3. Line 33 prints `14`. Line 34 prints `2`. Confidence: high.
4. Line 35 prints `-1 -2`. `eval("9 +")` underflows and `eval("1 2")` leaves a value on the stack. Line 39 prints `6`, since `eval("8 2 -")` succeeds and the handler never runs. Confidence: high.

### p11 — task list

1. `tasks[1].due` is still `none`. `postpone` only adds when the optional holds a value. Confidence: high.
2. Line 28 prints, in order:

```
rent -4
call -1
taxes 20
```

Confidence: high.

3. Line 31 prints `2 8`. Two tasks are not done, and "bring id" has eight characters. Confidence: high.
4. Yes. Line 32 pops the last task through a write borrow, so `tasks` shrinks to two. Line 33 prints `dropped taxes 25`. Line 34 prints `2`. Confidence: high.

### p12 — game

1. No. `+players` makes an independent copy, so later changes to `players` do not affect `start`. Confidence: high.
2. Lines 20 and 21 (pushes), lines 27 and 28 (write-borrowing loop whose body bumps each score), and lines 29 and 30 (write borrow of one player, then decrementing its lives). Line 19 only initializes. Confidence: high.
3. `done` is true when neither player is alive, meaning both have `lives` of zero or less. Confidence: high.
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Confidence: high.

The round trace is: round 1 both score 10 and ben loses his only life. Round 2 ana scores 30 and loses a life. Round 3 ana scores 60 and ben is targeted but already dead. Round 4 ana scores 100 and loses her last life, so both are dead.

### Rejected programs

- **r01, line 11.** `charge` takes `a: ?Account`, a read-only borrow, and line 11 writes `a.balance -= n` through it. Confidence: high.
- **r02, line 18.** Line 16 moved `r` into `archive` with `<r`, and line 18 reads `r.pages.len` after the move. Confidence: high.
- **r03, line 14.** `pop` mutates the vector but is called on `cart.items` with no write borrow. It needs `(!cart.items).pop()` or an equivalent. Confidence: high.
- **r04, line 14.** Line 13 stored a read-only borrow of `list[1]` in `top`, and `top` is still used on line 15. Line 14 pushes to `list` while that borrow is live, which would invalidate it. Confidence: high. p01 does the same pattern legally because `first` is never used after the write on line 26.

## Revised meanings

**Prefix symbols**

- `?expr`: read-only borrow. At a call site it is optional, since `value(items)` and `walk(root, !keys)` pass read-only borrows without it. Stored in a variable, the borrow stays live until its last use, and no write to the source may happen in between.
- `!expr`: write borrow. It is mandatory at every mutating call site and on every mutating method call. In statement position it is written in front of the whole chain, as in `!self.jobs.push(...)`. In expression position the receiver is parenthesized, as in `(!q).next()`.
- `!` in `if !slot as n` or `match !s`: unwrap through a write borrow, so the bound names are writable references into the payload.
- `?` and `!` on parameter types: read-only and write borrows, matching the call-site marks.
- `*Type` and `*Ctor(...)`: a shared, reference-counted handle. The destructor runs when the last handle goes away.
- `+expr`: make another handle to a shared value, or an independent copy of a plain value such as a `Vec`.
- `<expr`: give up ownership. As an argument it moves the value into the callee. As a standalone statement it releases the handle or destroys the value right there.
- `@size(T)`: compile-time size of a type in bytes.
- `.variant` inside `match`: a case of the matched enum.

**Postfix symbols**

- `T?`: optional type. `T!`: fallible result. `sub f(...)!`: fallible procedure.
- `expr!`: propagate a failure to the caller.
- `expr?`: propagate an empty optional, returning `none` from the enclosing function. This was not in the first three programs.
- `a ?? b`: default for an empty optional. The right side can be a `return`, as in `?? return Parse.bad`.
- `stmt if cond`: postfix conditional on any statement, including assignments and calls.

**Keywords and forms added later**

- `enum` with payload variants, `match` with `=>` arms, guards like `.circle(r) if r > 1`, a multi-line arm body, `_` catch-all, and `pass` for an empty arm.
- `drop(!self)` inside a struct: destructor.
- `Box[T]`: owned heap cell, used for recursive structures.
- `a if c else b`: conditional expression, including when both branches are write borrows.
- `for i in 0..n`: half-open range. `for p in !players`: iterate with write access. `continue`.
- `Text`, `U8`, `Int(b)`: a text type, a byte type, and a numeric conversion.
- Methods declared inside a struct with `?self` or `!self` as the first parameter.

**First guesses that were wrong or incomplete**

- I guessed the `!` prefix on a method call marks the call. It actually marks the receiver's write borrow, and the statement-versus-expression spelling difference was not something I anticipated.
- I assumed `?` at a call site was required. It is optional for reads and only `!` is enforced.
- I did not anticipate that a stored `?` borrow carries a lifetime that forbids later writes until its last use. r04 made that visible.
- I had no guess for `*`, `+`, `<`, `@size`, postfix `?` on expressions, or `??` followed by `return`.

## Where I hesitated

- **p01 line 31**, `not it.qty > 3`. I briefly read it as `(not it.qty) > 3`. The only type-correct reading is `not (it.qty > 3)`, so `not` binds looser than comparisons.
- **p02 line 29**, `(!ws).next()`. I wondered why this has parentheses when `!items.push` does not. I settled on statement-position sugar versus expression-position explicit borrow.
- **p03 line 28**, `catch |e| print(...)`. I paused on whether a handler can be a `print` call in a procedure context. It can, because the procedure yields nothing.
- **p03 line 33**. I nearly skipped the side effect in `report(ann)` and had to check that `or` evaluates it, which adds an `ann 70` line to the output.
- **p05 line 15**, `?? return Parse.bad`. I first read it as a syntax error, then accepted `return` as an expression on the right of `??`.
- **p05 line 31**, `digit(s[0])? * 100`. I first read the `?` as the start of a ternary. It is optional propagation.
- **p06 line 8**, `insert(!n.left if key < n.key else !n.right, key)`. I had to re-read to see that the conditional expression chooses between two write borrows and the trailing `key` is the second argument.
- **p07 line 20**, `<base`. I first saw a dangling comparison. It is a release of the handle. Similarly `+base` looked like unary plus before I understood it as sharing a handle, and `*Config` looked like a pointer dereference.
- **p07 line 23**. I had to count handles to decide whether `released base` printed at line 20, 23 or 25.
- **p08 line 21**, `+log.lines`. I hesitated between share and copy. `lines` is a plain `Vec`, not a `*` type, so it is a copy. r02 line 18 confirms the copy is independent.
- **p08 line 27**, `<tmp`. I had to decide if a standalone `<` drops immediately. The `close tmp` line is only interesting if it does.
- **p09 line 20**, `.circle(r) => r += by`. I checked that `match !s` makes `r` writable rather than a copy.
- **p09 line 34**, `@size(Pixel)`. I had to decide it is a byte count with no padding.
- **p11 line 15**, `due? - today` on a `?Int?` parameter. I checked that propagation works through a borrow of an optional.
- **p11 line 29**, `Text` versus `String`. I did not see `Text` before and had to assume `.len` counts characters.
- **p12 line 22**, `+players`. I checked whether it was a share or a copy. The vector is not a `*` type, so it is a copy.
- **p12 lines 27 to 30**. I had to confirm the write-borrowing loop ends before `target = !players[...]` takes a new write borrow.
- **r04 versus p01 lines 24 to 26**. Both store a `?` borrow and then write to the vector. The difference is whether the borrow is used afterward, which took a second comparison to see.

## Overall

**Rating: 6 out of 10.**

The core `?` and `!` scheme is consistent once learned. Read borrow versus write borrow on both parameter types and call sites, optional versus fallible on return types, and propagation on calls all line up, and the mandatory `!` at every mutating call site makes "where can this be modified" questions easy to answer by scanning. `not`, `and`, `or`, postfix `if`, `as` unwrapping and `catch` read almost like prose.

The costs are symbol overloading and a few cryptic ownership marks. `!` means write borrow before an expression and failure propagation after it, and `?` means read borrow, optional type, and optional propagation depending on position. The `*`, `+` and `<` ownership operators are not guessable from context, and `<` collides visually with less-than. The inconsistency between `!x.m()` and `(!x).m()` cost a re-read. Finally, the printed form of `none`, error values and vectors is not derivable from the code, which limits certainty on exact output for p03, p05 and p06.
