# Answers

## First guesses

Written after reading only p01.rig, p02.rig and p03.rig.

### Prefix symbols (directly before a name or type)

- `&` (as in `&Item`, `&Vec[Item]`, `&items[0]`, `&items`, `&entries`, `&top`, `&Entry?`):
  a read-only borrow / reference. On a type, `&T` is a parameter type
  meaning "a read-only reference to a T"; on an expression, `&x` creates
  such a reference (the callee or loop sees the value but cannot change
  it, and the caller keeps ownership).
- `@` (as in `@Item`, `@Account`, `@Vec[Entry]`, `@items.push(...)`,
  `@items[1]`, `@entries`, `@ws.next()`, `@from`):
  a mutable borrow / write reference. On a type, `@T` means "a reference
  through which I may modify the T"; on an expression, `@x` lends `x`
  mutably, and it is required at the call site whenever a method or
  function will modify the value (`@items.push`, `@ws.next()` advances an
  iterator). It makes mutation visible at the call site.
- `!` before an expression (`!in_stock(it)`, `!(it.qty > 3)`,
  `!(e.word == "the")`, `!bob.frozen`): logical NOT.
- `-` before a number (`-1`): unary minus / negative literal.

### Postfix symbols (directly after an expression or type)

- `?` after a type (`Int?`, `Entry?`, `&Entry?`): optional type, the
  value is either a T or `none`.
- `!` after a type (`Int!`): fallible type, either an Int or an error
  (from an `error` set such as `Bank`).
- `!` after a sub's parameter list (`sub transfer(...)!`): the sub can
  fail (returns nothing or an error).
- `!` after a call (`withdraw(@from, n)!`, `transfer(@ann, @bob, 30)!`):
  propagate the error: if the call fails, return that error from the
  current function immediately (like Rust's `?` or Zig's `try`). In
  `main` this probably aborts the program with the error.
- `??` (binary, after an expression): "or else default": if the left
  side is `none`, use the right side.

### Keywords I did not recognize (or that are unusual)

- `fun`: a function that returns a value (last expression is the result).
- `sub`: a subroutine / procedure; returns no value (or only an error
  when marked `!`). `sub main()` is the entry point.
- `struct`: record type, fields listed indented.
- `error Bank` with indented names: declares an error set / enum of
  error values (`Bank.frozen`, `Bank.insufficient`).
- `use std.text`: import a module; then referred to as `text.words`.
- `none`: the empty value of an optional type.
- `as` in `if expr as name` / `while expr as name`: unwrap an optional:
  if the value is not `none`, bind it to `name` and run the block
  (`while` keeps looping until it is `none`).
- `return x if cond`: postfix conditional (Ruby style).
- `catch |e| stmt` / `catch value`: handle a failure from a fallible
  call: with `|e|`, bind the error and run the handler; with a bare
  value, use that value as the result in case of failure.
- `and` / `or`: boolean operators.
- `Vec()` / `Vec[T]`: growable array; `[T]` is generic type arguments.

## Answers to questions.md

Assumption used throughout: `print(a, b, c)` prints its arguments
separated by single spaces, then a newline.

### p01 — inventory

1. Line 23 prints `32` (4*3 + 0*1 + 2*10). Confidence: high.
2. Line 25 prints `bolt 4`. Confidence: high.
3. `items` may be modified on lines 20, 21, 22 (`@items.push`) and 26
   (`restock(@items[1], 5)`). Line 28 (`&items`) and lines 23, 24, 25, 33
   only read it. Confidence: high.
4. After restock, quantities are bolt 4, nut 5, gear 2. Line 32 runs once
   (for gear, printing `low: gear`). Line 33 prints `37 0`
   (12 + 5 + 20 = 37; no item is out of stock, so `missing` is 0).
   Confidence: high.

### p02 — word counter

1. No. `find` takes `entries: &Vec[Entry]`, a read-only view; it cannot
   modify `entries`. Confidence: high.
2. Lines 16 (`entries[i].count += 1`, writing through the write view the
   sub received) and 18 (`@entries.push(...)`). Confidence: high.
3. Line 35 prints `top: cat 2`. Counts: the 3, cat 2, saw 1, dog 1,
   and 1, ran 1; the only entry with count != 1 that is not "the" is cat.
   Confidence: high.
4. Line 36 prints `6 3 -1` (6 distinct words; "dog" is at index 3;
   "cow" is not found, so `?? -1` gives -1). Confidence: high.

### p03 — bank ledger

1. After line 27: ann 70, bob 50. Confidence: high.
2. Line 28 prints `failed: insufficient` (bob has 50 < 80). No balance
   changes: `withdraw` fails before subtracting, and `to.balance += n`
   is never reached. Confidence: high on the behaviour, medium on the
   exact spelling of the error (it might print as `Bank.insufficient`
   or `error.insufficient`).
3. It passes a failure on (propagates the error from `withdraw` out of
   `transfer`). Confidence: high.
4. Line 33 evaluates `!bob.frozen` (false, bob is frozen), so `report(ann)`
   runs and prints `ann 70`; 70 != 70 is false, so line 34 does not run.
   Line 35 prints `bob 45` (bob withdrew 5 on line 29). Output:
   ```
   ann 70
   bob 45
   ```
   Confidence: high.

### p04 — job queue

1. It lends `q` for writing to `next`, which removes the first job from
   `q.jobs` and returns it; `q` loses its front job, and `job` owns it.
   Confidence: high.
2. While `q` is not empty (`q.is_empty()` is false). Confidence: high.
3. In order:
   ```
   ran 1 5
   ran 3 1
   ran 4 0
   ```
   (job 2, cost 7, is skipped when the budget is 5.) Confidence: high.
4. Line 33 prints `2 0 0 false`. Confidence: high.

### p05 — expression parser

1. When the byte `b` is not a decimal digit character. Confidence: high.
2. Yes. `pos` is lent for writing (`@pos`), and `number` advances it past
   the digits it read, to the `+` or the end of the string.
   Confidence: high.
3. Line 35 prints `-1 -2` ("4+x" fails with `Parse.bad` at `x`; "5++6"
   fails with `Parse.empty` at the second `+`). Confidence: high.
4. Line 36 prints `700 none 0`. `lead("7up")` is 7*100 = 700;
   `lead("up7")`: `digit('u')` is none and the postfix `?` passes the
   none on; `lead("")` is none, and `?? 0` makes it 0. Confidence: medium
   (the values are certain; how a `none` optional prints is a guess,
   possibly `null`).

### p06 — binary tree

1. Lines 33 and 38 (`insert(@root, ...)`). Confidence: high.
2. `walk` may not modify `root` (its parameter is `&Box[Node]?`, read
   only); it may modify `keys` (passed as `@keys` to an `@Vec[Int]`
   parameter). Confidence: high.
3. Line 36 prints `[20, 30, 40, 50, 70] 210` (in-order walk; sum 210).
   Confidence: high on the values, medium on the list formatting.
4. Yes, line 38 runs (45 is not in the tree), and line 39 prints
   `255 true`. Confidence: high.

### p07 — shared configuration

1. Line 19 prints `2 2`. Confidence: high.
2. No. `<base` gives up only the `base` handle; `web.config` and
   `db.config` still hold the shared Config, so it is not released.
   Confidence: high.
3. Line 25 (`<web`). By then `db.config` has been pointed at `debug`
   (line 23), so `web.config` is the last handle to "base"; dropping
   `web` drops it and prints `released base`. Confidence: high.
4. `db` (moved into `running` by `<db`). Confidence: high.

### p08 — files

1. Line 23 prints `2 3`. Confidence: high.
2. No. `backup` got a clone (`+log.lines`) of log's lines; appending to
   `backup` does not touch `log`. Confidence: high.
3. `log` (moved into `archive` by `<log`). Confidence: high.
4. ```
   archive app.log 2
   close app.log
   after archive
   close tmp
   end 3
   close app.bak
   ```
   (`archive` owns the File and drops it at its end; `<tmp` drops tmp
   immediately; `backup` is dropped when `main` ends.) Confidence: high
   on order of the first five lines, medium on `close app.bak` being
   printed last at the end of main (high that it is printed).

### p09 — shapes

1. Yes. `shapes[1]` is `rect(w: 3, h: 4)`; `grow` adds 2 to `w` and
   multiplies `h` by 2, so it becomes `rect(w: 5, h: 8)`. Confidence: high.
2. ```
   12
   40
   0
   ```
   Confidence: high.
3. `big circle 2`. Confidence: high.
4. `400 false` (`$size(Pixel)` is 4 bytes, times 100; the dot's area is
   0). Confidence: medium-high (assumes `$size` is size in bytes with no
   padding, which holds for four U8 fields).

### p10 — stack calculator

1. `stack` is lent for writing to `pop`, which removes its last element;
   if there was one, it is bound to `x` and returned; if the stack was
   empty nothing changes and `take` returns `Calc.underflow`.
   Confidence: high.
2. A failure propagation. Confidence: high.
3. Line 33 prints `14`; line 34 prints `2`. Confidence: high.
4. Line 35 prints `-1 -2` ("9 +" underflows; "1 2" leaves an item, so
   `Calc.leftover`). Line 39 prints `6` (no error, so the catch block,
   and its `error:` print, does not run). Confidence: high.

### p11 — task list

1. `none` (it was none, and `postpone` changes it only if it holds a
   value). Confidence: high.
2. ```
   rent -4
   call -1
   taxes 20
   ```
   (taxes was postponed from 15 to 25.) Confidence: high.
3. `2 8` (call and taxes are not done; "bring id" has 8 characters).
   Confidence: high.
4. Yes, `pop` removes the last task (taxes). Line 33 prints
   `dropped taxes 25`, and line 34 prints `2`. Confidence: high.

### p12 — game

1. No. `+players` makes an independent clone. Confidence: high.
2. Lines 20, 21 (push), 27 (`for p in @players`, a writing loop), 28
   (`bump(@p.score, ...)`), 29 (`target = @players[...]`, a write view)
   and 30 (`target.lives -= 1`, writing into players through that view).
   Confidence: high (medium on whether you count 27 and 29 themselves or
   only 28 and 30 where the write happens).
3. When both players are dead (lives 0 for both). Confidence: high.
4. Line 32 prints `4 ana 10`; line 33 prints `0 true`.
   Trace: round 1: ana 10, ben 10, ben loses his life (0). Round 2:
   ana 30, ana lives 1. Round 3: ana 60, target ben is dead, no change.
   Round 4: ana 100, ana lives 0; both dead. Confidence: high.

### Rejected programs

- **r01: line 11.** `a.balance -= n` modifies `a`, but `charge` received
  `a: &Account`, a read-only view. (It would need `@Account` and the
  call `charge(@acct)`.) Confidence: high.
- **r02: line 18.** `r.pages.len` uses `r` after line 16 moved it into
  `archive` (`<r`); `r` was already archived and dropped ("shred q3").
  Confidence: high.
- **r03: line 14.** `cart.items.pop()` modifies `cart.items` without
  marking it with `@`; it must be `@cart.items.pop()`, as every other
  mutating method call in these programs is written. Confidence:
  medium-high (the alternative would be a complaint about `??` on line 15,
  but `pop` returns an optional elsewhere, so that line is fine).
- **r04: line 14.** `@list.push(...)` modifies `list` while `top`, a read
  view into `list[1]` taken on line 13, is still live (used on line 15);
  the push could reallocate the Vec and leave `top` dangling.
  Confidence: high.

## Revised meanings

- `&x` / `&T`: lend for reading / read-only view. Confirmed. Revision: at
  a call site, the `&` seems optional when the parameter is already `&T`
  (`value(items)`, `walk(root, ...)`, `contains(root, 45)`, `report(ann)`,
  `level_of(web)` next to `level_of(&db)`, `area(shapes[2])`), and
  `for t in tasks` reads like `for t in &tasks`. So reading needs no mark,
  writing always does. Also `&` works on optionals in `if &note as n`.
- `@x` / `@T`: lend for writing / writable view. Confirmed. It is needed
  on every mutating method call (`@q.next()`, `@stack.pop()`), on a
  writing loop (`for p in @players`), on a match that writes into the
  bound fields (`match @s`), on `if @slot as n` to bind a writable view
  into an optional, and on `self` in methods (`@self` / `&self`).
  Assignments through an already-writable view (`it.qty += n`,
  `slot = Box(...)`, `target.lives -= 1`) need no mark.
- `!x` (prefix): logical not. Confirmed.
- `-x` (prefix): negation. Confirmed.
- `*x` / `*T` (new in p07): shared, reference-counted value/handle.
  `*Config(...)` creates one; `*Config` is the field type.
- `+x` (new in p07, p08, p12): clone. On a shared handle, it makes another
  handle to the same object (bumps the count); on a Vec, an independent
  copy.
- `<x` (new in p07, p08): move. As an argument it hands ownership over
  (`archive(<log)`, `push(<db)`); as a bare statement (`<base`, `<tmp`)
  it moves the value out to nowhere, i.e. drops it now. The variable is
  unusable afterwards.
- `T?`: optional type. Confirmed.
- `expr?` (postfix on an expression, new in p05 and p11): if the value is
  `none`, return `none` from the current function; otherwise unwrap it
  (`digit(s[0])? * 100`, `due? - today`).
- `T!` and `sub f(...)!`: fallible. Confirmed.
- `expr!` (postfix on an expression): propagate the failure. Confirmed.
- `??`: default for `none`; the right side can even be `return ...`
  (p05 line 15).
- `catch v` / `catch |e| ...`: handle a failure, with a value or with an
  indented block whose last expression is the value (p10 line 36).
  Confirmed.
- `$size(T)` (new): a compiler builtin; size of the type in bytes.
- `..` (new): half-open range (`0..players.len`).
- `match`, `.variant(fields) =>`, guards `if`, `_`, `pass`, `enum` with
  payload variants: pattern matching as expected.
- `drop(@self)` in a struct: destructor, run when the value is dropped.
- `x if c else y`: conditional expression; `stmt if c`: postfix condition.

Which first guesses were wrong: none outright. Two were incomplete: I did
not anticipate that the `&` is optional at a read call site (I first
assumed it was always required), and I had `?` only as a type suffix,
not as a "propagate none" expression suffix. My guess that a trailing
`!` in `main` aborts the program is untested by these programs.

## Where I hesitated

- p02 line 33 and p03 line 33, `!(e.word == "the")`, `!bob.frozen`:
  `!` is both prefix "not" and postfix "propagate failure" (and a type
  suffix "fallible"). On p03 line 33 I briefly checked whether
  `!bob.frozen` could be a write-lend like `@`; it is not.
- p03 line 16, `sub transfer(...)!`: the `!` after the parameter list
  first read as a typo; it marks the sub as fallible.
- p01 line 23 / p06 line 35 / p03 line 33: `value(items)` and
  `walk(root, @keys)` pass a value without `&` to a `&` parameter. I
  first wondered whether these were copies or moves; I settled on
  implicit read lends, since the variables are used afterwards.
- p02 line 34, `top = e`: assigning a read view `e` to `top: Entry?`. I
  first thought it was a type error or a move; I took it as a copy of the
  entry into the optional (or `top` holding a view). The printed result
  is the same either way.
- p05 line 15, `?? return Parse.bad`: `return` used as an expression on
  the right of `??`; I had to re-read it.
- p05 line 31 and p11 line 15, `digit(s[0])? * 100`, `due? - today`:
  at first `?` followed by an operator looked like a ternary; it is the
  postfix "propagate none".
- p05 line 14, `s[pos] != 43`: 43 is the byte code of `+`; I had to work
  that out.
- p06 line 8, `insert(@n.left if key < n.key else @n.right, key)`: a
  conditional expression choosing between two write views; read twice.
- p06 lines 7 and 10: `if @slot as n` then, in the else branch,
  `slot = Box(...)` assigns into the caller's optional through the write
  view. Re-read to be sure it writes the caller's `root`.
- p07 line 16 / 10, `*Config(...)` and `*Config`: first read as a
  pointer dereference / pointer type (C), then understood as shared.
- p07 lines 17 and 23, `+base`: first read as unary plus (no-op); it is
  a clone of the handle.
- p07 line 20, `<base` alone on a line: first looked like a stray
  less-than or a shell redirect; it is move/drop now.
- p08 line 24, `archive(<log)`: "less-than log"; read as a move once I
  saw the `drop` output.
- p09 line 19, `match @s` with `r += by` in the arm: the bindings are
  writable because the scrutinee was lent for writing.
- p09 line 34, `$size(Pixel)`: unknown `$` prefix; guessed size in bytes.
- p11 line 30, `if &note as n`: optional unwrapping with a read view;
  `Text` vs `String` (both seem to be strings; `n.len` is 8).
- p12 lines 29–30: `target = @players[round % 2]` creates a write view
  that is then written through without `@` (`target.lives -= 1`), while
  `alive(target)` reads it. I re-read to confirm this modifies `players`.
- r03 line 14: the missing `@` on `cart.items.pop()` is easy to miss; I
  first looked at the `??` on line 15.

## Overall

7/10. The ownership sigils are compact and, once seen in context,
consistent: `@` reads naturally as "writable" and appears at every site
that mutates, which made the "where may X be modified" questions easy.
`&`, `?`, `!`, `??` and `catch` match conventions from Rust, Swift and
Zig. What cost time: `!` carries three meanings (not, fallible type,
propagate failure), `<x` looks like a comparison and `+x`/`*x` look like
arithmetic and pointer operators until you see them used, and the
optional `&` at read call sites (sometimes written, sometimes not) made
me pause each time. The Python/Ruby-like layout (indentation, postfix
`if`, `x if c else y`) was effortless.
