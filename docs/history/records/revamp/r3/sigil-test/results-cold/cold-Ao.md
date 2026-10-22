# Answers

## First guesses

(Written after reading only p01, p02, p03.)

### Prefix symbols

- `?T` in a parameter type (`it: ?Item`, `items: ?Vec[Item]`, `best: ?Entry?`): a read-only
  borrow / shared reference to a `T`. The callee can look but not change it.
- `!T` in a parameter type (`it: !Item`, `entries: !Vec[Entry]`, `a: !Account`): a mutable
  (exclusive) borrow of a `T`. The callee may change the caller's value.
- `?x` at a use site (`first = ?items[0]`, `for it in ?items`, `report(?top)`): explicitly take a
  read-only borrow of `x` here. `first` is a view into `items[0]`, not a copy; the loop
  iterates by reference rather than consuming/copying.
- `!x` at a use site (`!items.push(...)`, `restock(!items[1], 5)`, `add(!entries, w)`,
  `transfer(!ann, !bob, 30)`, `(!ws).next()`): explicitly take a mutable borrow of `x` here,
  marking at the call site that `x` will be changed. `!items.push(...)` reads as "mutably
  borrow items, then call push"; `(!ws).next()` advances an iterator in place.
- `-1`: ordinary numeric negation.
- `not`: boolean negation (keyword, not a symbol).

### Postfix symbols

- `T?` on a type (`Int?`, `Entry?`): optional type, value or `none`.
- `T!` on a type (`-> Int!`): fallible result; either an `Int` or an error (from an `error` set).
- `)!` after a `sub` signature (`sub transfer(...)!`): this subroutine can fail (returns an error
  or nothing).
- `expr!` after a call (`withdraw(!from, n)!`, `transfer(...)!`): propagate the error to the
  caller if the call failed (like Zig `try` / Rust `?`). In `main`, presumably an unhandled
  error aborts the program.
- `??` (infix, between expressions): "or else" default for an optional
  (`find(...) ?? -1` gives -1 when `none`).

### Keywords I don't recognize / am guessing at

- `fun`: a function that returns a value (last expression is the result).
- `sub`: a subroutine/procedure with no return value (called for its effect).
- `struct`: record type with named fields; constructed `Item(name: ..., qty: ...)`.
- `error Bank` with indented names: declares an error set with members `Bank.insufficient`,
  `Bank.frozen`.
- `use std.text`: import a module; then `text.words(...)` is a function in it, returning an
  iterator over words.
- `none`: the empty optional value.
- `if expr as name`: if-let; if the optional `expr` has a value, bind it to `name` for the
  then-branch. `while expr as w` loops while the optional is non-`none`.
- `return x if cond`: postfix conditional return.
- `catch |e| stmt`: handle an error from the preceding fallible call, binding the error to `e`.
  `catch 0`: use `0` as the value if the call failed.
- `and`, `or`, `not`: boolean operators.
- `Vec()`, `Vec[T]`: growable array type, generic argument in square brackets.
- `.len`: length as a field/property.

## Answers to questions.md

Assumptions used throughout: `print(a, b, ...)` prints its arguments separated by single spaces,
then a newline. An argument passed to a `?T` parameter with no sigil (e.g. `value(items)`) is
lent for reading implicitly.

### p01 — inventory

1. `32` (4*3 + 0*1 + 2*10). Confidence: high.
2. `bolt 4`. Confidence: high.
3. Lines 20, 21, 22 (the three `!items.push`) and 26 (`restock(!items[1], 5)`, nut's qty
   becomes 5). Lines 23, 24, 28 only read. Confidence: high.
4. Line 32 runs once (prints `low: gear`; bolt has qty 4 and nut now has 5, both > 3).
   `missing` stays 0, since every item is in stock after the restock. Line 33 prints `37 0`
   (4*3 + 5*1 + 2*10 = 37). Confidence: high.

### p02 — word counter

1. No. Its parameter is `?Vec[Entry]`, a read-only view. Confidence: high.
2. Line 16 (`entries[i].count += 1`) and line 18 (`!entries.push(...)`). Line 15 only reads.
   Confidence: high.
3. `top: cat 2`. The entries are the 3, cat 2, saw 1, dog 1, and 1, ran 1. The only entry with a
   count other than 1 that is not "the" is cat. Confidence: high.
4. `6 3 -1` (six distinct words, "dog" is at index 3, "cow" is missing). Confidence: high.

### p03 — bank ledger

1. ann 70, bob 50. Confidence: high.
2. It prints `failed: insufficient` because bob has 50 and the transfer needs 80. No balance
   changes, since `withdraw` returns before subtracting and `to` is never touched. I'm not sure
   how an error value prints: it might be `insufficient`, `Bank.insufficient` or
   `error.insufficient`. Confidence: high that it fails with no change; medium on the exact text.
3. It passes a failure on: if `withdraw` fails, `transfer` fails with the same error.
   Confidence: high.
4. Line 33: `not bob.frozen` is false, so `report(ann)` runs and prints `ann 70`. It returns 70,
   so `70 != 70` is false and line 34 does not run. Line 35 prints `bob 45` (bob paid 5 on
   line 29; line 32 failed with `frozen`). Output:
   ```
   ann 70
   bob 45
   ```
   Confidence: high.

### p04 — job queue

1. It lends `q` for writing and calls `next`, which removes and returns the first job.
   `q.jobs` shrinks by one. Confidence: high.
2. The loop keeps going while the queue is not empty (`q.jobs.len != 0`). Confidence: high.
3. In order:
   ```
   ran 1 5
   ran 3 1
   ran 4 0
   ```
   Job 2 (cost 7 > 5) is skipped. Confidence: high.
4. `2 0 0 false`. Confidence: high.

### p05 — expression parser

1. When the byte `b` is not an ASCII digit character. Confidence: high.
2. Yes. `pos` is lent for writing (`!pos`), and `number` advances it past the digits it reads,
   to the `+` or the end of the string. Confidence: high.
3. `-1 -2`. "4+x" fails with `Parse.bad` because 'x' is not a digit. "5++6" fails with
   `Parse.empty` because the second number is empty. Confidence: high.
4. `700 none 0`. `lead("up7")` is none because the postfix `?` on `digit('u')` passes the none
   on. I'm not sure how a none optional prints: it might be `none` or `null`, and `700` might
   print with a wrapper. Confidence: high on the values; low-medium on the exact text.

### p06 — binary tree

1. Lines 33 and 38 (`insert(!root, ...)`). Confidence: high.
2. `walk` may not modify `root` (parameter `?Box[Node]?`, passed as a read). It may modify `keys`
   (parameter `!Vec[Int]`, passed as `!keys`). Confidence: high.
3. `[20, 30, 40, 50, 70] 210`. This is an in-order walk of the tree with 50 at the root,
   30 and 70 under it, and 20 and 40 under 30. Confidence: high on the contents and the sum;
   medium on how a Vec prints.
4. Yes. 45 is not in the tree, so line 38 runs and inserts 45 to the right of 40. Line 39
   prints `255 true`. Confidence: high.

### p07 — shared configuration

1. `2 2`. Confidence: high.
2. No. `base` is only one of three handles (`web` and `db` each hold a clone), so dropping it
   only lowers the count. Confidence: high.
3. Line 25 (`<web`). After line 23, `db` points at debug, so `web` holds the last handle to base.
   Dropping it prints `released base`, before line 26 prints `dropped web`. Confidence: high.
4. `db`, which is moved into `running` on line 28. (`base` and `web` were already given up on
   lines 20 and 25.) Confidence: high.

For reference, the full output I expect: `2 2`, `dropped base handle`, `9 2`,
`released base`, `dropped web`, `1 9`, `end of main`, `released debug`.

### p08 — files

1. `2 3`. Confidence: high.
2. No. `backup` got a clone (`+log.lines`), so pushing to it does not touch `log`.
   Confidence: high.
3. `log`, which is moved into `archive`. Confidence: high.
4. In order:
   ```
   archive app.log 2
   close app.log
   after archive
   close tmp
   end 3
   close app.bak
   ```
   Confidence: high on the order (medium on the timing of `close app.log`, which I take to be
   when `archive` returns).

### p09 — shapes

1. Yes. `shapes[1]` is `rect(w: 3, h: 4)` and becomes `rect(w: 5, h: 8)` (w += 2, h *= 2).
   Confidence: high.
2. In order:
   ```
   12
   40
   0
   ```
   Confidence: high.
3. `big circle 2`. Confidence: high.
4. `400 false`. `Pixel` is four U8s, so 4 bytes. Confidence: high (medium on `@size` being bytes).

### p10 — stack calculator

1. `stack` is lent for writing and its last element is popped (removed). If there was one, it is
   bound to `x`. Confidence: high.
2. A failure propagation: if `take` fails, `apply` fails with the same error. Confidence: high.
3. Line 33 prints `14` ((3+4)*2). Line 34 prints `2` (5 - (1+2)). Confidence: high.
4. Line 35 prints `-1 -2`. "9 +" underflows, and "1 2" leaves an item on the stack, so it fails
   with leftover. Line 39 prints `6`. "8 2 -" succeeds, so the catch block on lines 37–38 does
   not run. Confidence: high.

### p11 — task list

1. `none`. It was none, and `postpone` changes it only if it has a value. Confidence: high.
2. In order:
   ```
   rent -4
   call -1
   taxes 20
   ```
   rent is due 1, and 1 - 5 = -4. call has no due date, so the result is -1. taxes was postponed
   from 15 to 25, and 25 - 5 = 20. Confidence: high.
3. `2 8`. Two tasks are not done (call and taxes), and "bring id" has 8 bytes.
   Confidence: high.
4. Yes. It removes the last task (taxes) from `tasks`. Line 33 prints `dropped taxes 25`.
   Line 34 prints `2`. Confidence: high.

### p12 — game

1. No. `start` is a clone (`+players`). Confidence: high.
2. Lines 20, 21 (push), 27–28 (`for p in !players` and `bump(!p.score, ...)` change scores),
   and 29–30 (`target = !players[...]`, then `target.lives -= 1` changes a player).
   Confidence: high.
3. When neither player is alive, that is, both have `lives` of 0. Confidence: high.
4. Rounds: (1) both +10, ben loses his life. (2) ana +20 = 30, ana goes to 1 life.
   (3) ana +30 = 60, ben is already dead. (4) ana +40 = 100, ana goes to 0 lives, done.
   ```
   4 ana 10
   0 true
   ```
   Confidence: high.

### Rejected programs

- **r01, line 11.** `charge` takes `a: ?Account`, a read-only view, but line 11 writes
  `a.balance -= n`. The parameter would need to be `!Account` (and the call `charge(!acct)`).
  Confidence: high.
- **r02, line 18.** `r` was moved into `archive` on line 16 (`<r`), so `r.pages.len` uses a
  moved value. Confidence: high.
- **r03, line 14.** `cart.items.pop()` changes `cart.items` but is not marked as a write. It needs
  `(!cart.items).pop()`, as `(!tasks).pop()` is written in p11. Confidence: medium-high. (Once
  that is fixed, `last ?? "nothing"` on line 15 is fine, since `pop` returns an optional.)
- **r04, line 14.** `top` is a read view into `list[1]` that is still used on line 15, so
  pushing to `list` (which could reallocate it) while the view is alive is a conflicting write.
  Confidence: high.

## Revised meanings

| Symbol | Final meaning | First guess right? |
|---|---|---|
| `?T` (type) | Read-only view of a `T`, borrowed from the caller | Right |
| `!T` (type) | Writable view of a `T`; the caller's value is changed | Right |
| `?x` (use) | Lend `x` for reading here. It can be left out at a call to a `?T` parameter (`value(items)`, `walk(root, ...)`). `first = ?items[0]` makes a view that lives until its last use | Right, but I didn't know it was optional |
| `!x` (use) | Lend `x` for writing here, and required for every write through a method or call (`!items.push`, `(!ws).next()`, `match !s`, `if !slot as n`, `for t in !tasks`). Leaving it out of a call to a mutating method is rejected (r03) | Right |
| `<x` | Move `x`. The source can't be used afterwards. As a bare statement (`<base`, `<tmp`) it gives up the value now: it drops an owned value, or releases one handle of a shared one | Not seen in p01–p03 |
| `+x` | Clone (a deep copy of a Vec; one more handle of a `*T`, with no copy of the data) | Not seen |
| `*T` / `*expr` | Shared, reference-counted value or handle; `*Config(...)` allocates one | Not seen |
| `-x` | Ordinary negation in every case I saw (`-1`) | Right |
| `T?` | Optional type | Right |
| `T!` / `sub f()!` | Fallible type, or a sub that can fail | Right |
| `expr!` | Propagate a failure to the caller | Right |
| `expr?` | Propagate `none`: if `expr` is none, the enclosing function returns none (`digit(s[0])? * 100`, `due? - today`) | Not seen in p01–p03; the postfix `?` form is new |
| `??` | Default for none, and the right side may be a control-flow expression (`?? return Parse.bad`) | Right; the `return` form surprised me |
| `@size(T)` | Built-in: the size of a type in bytes | Not seen |
| `drop(!self)` | Destructor, run when the value dies | Not seen |
| `catch |e| <block>` | Handle a failure, binding the error; the block's last expression is the value | Right |

None of my first guesses turned out to be wrong. They were incomplete: I didn't know that `?x` is
optional at a read-lend call site, or that a postfix `?` on an expression exists.

## Where I hesitated

- **p01 line 20 `!items.push(...)`.** I first wondered whether `!` negated the result of `push`
  (as in C `!f()`). Then I took it to mean "lend items for writing, then call push". The
  parenthesized form `(!ws).next()` in p02 and `(!q).next()` in p04 made me re-read: when are the
  parentheses needed? I concluded that `!a.b.c(...)` lends the receiver `a.b`, and `(!x).m()` is
  the same thing written explicitly. The two spellings feel inconsistent.
- **p01 line 31 `not it.qty > 3`.** I had to settle precedence. I took it as
  `not (it.qty > 3)`, since `(not it.qty) > 3` does not type-check.
- **p01 line 23 `value(items)` vs line 28 `for it in ?items`.** Why is `?` written in one place
  and not the other? I concluded that a read lend may be implicit.
- **p02 line 20 `best: ?Entry?`.** Is that a view of an optional, or an optional view? I read it
  as a read view of an `Entry?`.
- **p02 line 34 `top = e`.** `e` is a read view and `top` is an owned `Entry?`. Is this a copy?
  I assumed a copy, which doesn't change the output.
- **p03 lines 16–17 `)!` and `!` at line end.** At first I mixed up postfix `!` (failure) with
  prefix `!` (write lend). The same character means two unrelated things depending on its side.
  Line 27, `transfer(!ann, !bob, 30)!`, has both.
- **p05 line 15 `?? return Parse.bad`.** I didn't expect `return` as the right side of `??`.
- **p05 line 31 `digit(s[0])? * 100`.** At first glance this looked like a ternary or an
  optional-chaining operator, not "return none if none".
- **p05 line 35 `catch -1`.** For a moment I read this as "catch minus 1", a subtraction.
- **p06 line 8 `!n.left if key < n.key else !n.right`.** I re-read this to confirm it's a
  conditional expression that picks which child to lend for writing.
- **p07 line 16 `*Config(...)`.** My first reaction was C dereference or pointer. Line 10
  (`config: *Config`) and the `+base` clones made it read as a shared, refcounted handle.
- **p07 line 20 `<base`.** A lone `<` at the start of a line first looked like a typo or a
  redirect. The print on line 21 told me it gives up the handle. Then I had to track refcounts to
  see that `released base` doesn't print until line 25.
- **p07 line 17 `+base`.** At first I read it as unary plus, which would be a no-op.
- **p08 line 21 `+log.lines`.** Clone of `log.lines`, or `+` applied to `log` then `.lines`?
  I read it as a clone of the field.
- **p09 line 19 `match !s` and line 32 `match ?shapes[0]`.** These are the same sigils on a
  match scrutinee, so the bindings are writable or read-only views.
- **p11 line 29 `Text` vs `String`.** I'm not sure what the difference is (owned vs borrowed
  string?). It doesn't change the answer.
- **p12 line 29 `target = !players[round % 2]`.** A named write view held across a line. I checked
  that it ends before `players[0]` is read on line 31.
- **r03 line 14.** It took a moment to see that this was the error: it looks like ordinary code,
  and the only thing missing is the `!` that marks the write.

## Overall

**7/10.** Once I guessed the core pair (`?` = read, `!` = write), most programs read quickly,
and the call-site sigils made it obvious which lines can change what (questions like "which lines
modify X" became a search for `!`). The indentation syntax, `fun`/`sub`, postfix `if`, `as`
bindings and `catch` all read naturally. The cost:

- `!` and `?` each carry two unrelated meanings depending on side. Prefix means write or read
  lend; postfix means propagate failure or propagate none. A line like
  `transfer(!ann, !bob, 30)!` takes a moment.
- `<x` as a bare statement and `*` for shared values are not guessable from mainstream languages.
- The rule for when parentheses are needed (`(!ws).next()` vs `!items.push`) isn't obvious.
- A read lend can be implicit while a write lend can't. This is sensible, but it made me doubt
  myself the first time.
