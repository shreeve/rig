# Cold reading of Rig (set A)

## First guesses (after p01-p03 only)

Prefix symbols
- `?` before a type (`it: ?Item`, `?Vec[Item]`) = read-only borrowed view of the value. Before an expression (`?items[0]`, `report(?top)`) = take a read-only reference.
- `!` before a type (`it: !Item`, `!Vec[Entry]`) = mutable borrow (write access). Before an expression (`!items.push(..)`, `restock(!items[1], 5)`, `withdraw(!from, n)`) = pass or use it mutably; the call site marks that the callee may change it.
- `-` in `-1` is ordinary negation. `not` is logical not.
- `(!ws).next()` = take a mutable borrow of ws, then call next on it.

Postfix symbols
- `T?` (`Int?`, `Entry?`, `?Entry?`) = optional type (value or `none`).
- `T!` (`-> Int!`) and `sub transfer(...)!` = the function may fail with an error. `!` after a call (`withdraw(!from, n)!`, `transfer(...)!`) = propagate the error to the caller, like Rust's `?` or Zig's `try`.
- `??` = default if none (`find(...) ?? -1`).
- `!` suffix on a call with `catch` after it: `catch |e| ...` handles the error, `catch 0` supplies a default.

Unrecognized keywords
- `fun` = function returning a value; `sub` = procedure with no return value (maybe also "may mutate"). `error Bank` with members = an error set/enum. `use` = import. `as i` in `if find(..) as i` = unwrap an optional into a new name if present. `none` = null. `catch |e|` = error handler with a binding. `->` = return type. `struct`, `while`, `for .. in`, `return X if cond` (postfix if), `and`, `not`, `or` are familiar.
- Unclear: whether a bare name passed (`value(items)`, `report(ann)`) is auto-lent as read-only; I guessed yes because callee takes `?`.

## Answers

### p01
1. Line 23 prints `32` (4*3 + 0*1 + 2*10). Confidence high.
2. Line 25 prints `bolt 4`. High.
3. Lines 20, 21, 22 (push) and 26 (`restock(!items[1], 5)`). Not 23 or 24 (read-only), not 28 (read lend). High.
4. Line 32 runs once (the `not it.qty > 3` parses as `not (it.qty > 3)`; only gear, qty 2, qualifies; nut has qty 5 after restock). It prints `low: gear` once. Line 33 prints `37 0` (value = 12+5+20; missing = 0 since all have stock). High.

### p02
1. No. `find` takes `?Vec[Entry]`, a read-only view. High.
2. Line 16 (`entries[i].count += 1`) and line 18 (`!entries.push`). High.
3. Line 35 prints `top: cat 2`. High.
4. Line 36 prints `6 3 -1` (6 distinct words, dog at index 3, cow absent). High.

### p03
1. ann = 70, bob = 50. High.
2. Line 28 prints `failed: insufficient` (possibly with the error name shown as `Bank.insufficient`; exact formatting medium). No balance changes (withdraw returns before subtracting). Confidence high on no change, medium on exact text.
3. It passes a failure on (propagates the error). High.
4. Line 33: `not bob.frozen` is false, so `report(ann)` runs and prints `ann 70`; `70 != 70` is false so the condition is false and line 34 does not print. Line 35 prints `bob 45` (line 29 withdrew 5 from bob's 50). So output: `ann 70` then `bob 45`. High.

### p04
1. Line 26 mutably borrows `q` and removes the first job from the front of its queue (q shrinks by one). High.
2. While the queue is not empty. High.
3. `ran 1 5`, `ran 3 1`, `ran 4 0` (job 2 costs 7 > remaining 5 and is skipped). High.
4. `2 0 0 false` (retry = 2, skipped now empty, queue empty, budget 0). High.

### p05
1. When the byte `b` is not a digit character. High.
2. Yes, `pos` is advanced by the callee (passed as `!pos`). High.
3. Line 35 prints `-1 -2` (`4+x` gives Parse.bad, `5++6` gives Parse.empty). High.
4. Line 34 prints `49`. Line 36 prints `700 none 0` (lead("up7") is none; how none is rendered is medium confidence). Medium-high.

### p06
1. Lines 33 (`insert(!root, k)`, in the loop) and 38 (conditional insert). High.
2. `walk` may not modify `root` (read view); it may modify `keys` (passed `!keys`). High.
3. Line 36 prints `[20, 30, 40, 50, 70] 210` (list formatting medium). High on values.
4. Line 38 runs (45 is not in the tree). Line 39 prints `255 true`. High.

### p07
1. Line 19 prints `2 2`. High.
2. No. Only the `base` handle is dropped; web and db still hold the config. High.
3. Line 25 (`<web`): the last remaining handle to base goes away, printing `released base` (right before `dropped web`). Medium-high (db.config was swapped on line 23, so web is the last holder).
4. `db` (moved into `running` on line 28). High.

### p08
1. Line 23 prints `2 3`. High.
2. No. `+log.lines` clones the vector; backup appends to its own copy. High.
3. `log` (moved into archive). High.
4. In order:
   - `archive app.log 2`
   - `close app.log`
   - `after archive`
   - `close tmp`
   - `end 3`
   - `close app.bak`
   Medium-high on ordering of the drop messages (end-of-scope drop of backup after the final print).

### p09
1. Yes: `shapes[1]` (the rect) is changed in place from rect(3,4) to rect(5,8). High.
2. Lines 29-30 print `12`, `40`, `0` on three lines. High.
3. Line 32 prints `big circle 2`. High.
4. Line 34 prints `400 false`. Medium-high (@size(Pixel) = 4 bytes).

### p10
1. `stack` is lent for writing; the last element is popped off (removed). High.
2. Failure propagation. High.
3. Line 33 prints `14`; line 34 prints `2`. High.
4. Line 35 prints `-1 -2`; line 39 prints `6`. High.

### p11
1. `none` (postpone does nothing for none). High.
2. `rent -4`, `call -1`, `taxes 20`. High.
3. `2 8`. High.
4. Yes, line 32 pops (removes) the last task. Prints `dropped taxes 25` on line 33; line 34 prints `2`. High.

### p12
1. No. `+players` is a clone, an independent copy. High.
2. Lines 20, 21, 27, 28 (via `!p.score`), 29, 30 (via `target`). High.
3. When both players have lives <= 0 (neither alive). High.
4. Line 32 prints `4 ana 10`; line 33 prints `0 true`. High.

### Rejected programs
- r01: line 11. `a` is a read view (`?Account`), and `a.balance -= n` writes through it.
- r02: line 18. `r` was moved on line 16 (`archive(<r)`), so `r.pages.len` uses a moved value.
- r03: line 14. `cart.items.pop()` mutates without the `!` write lend (needs `(!cart.items).pop()`).
- r04: line 14. `top` is a live read view into `list`; pushing mutates `list` while `top` is used on line 15 (the push could reallocate).
All high confidence on the line; r03 medium on the reason (the missing `!` seems the likelier one given p04/p10).

## Revised meanings
- `?x` / `?T`: read-only lend / read view. Confirmed. Also usable for stored views (`first = ?items[0]`).
- `!x` / `!T`: lend for writing / write view. Confirmed. Method calls that mutate need `!` on the receiver (`!items.push(..)`, or `(!ws).next()` when the receiver is an expression with a following call/`as`).
- `<x`: move (ownership transferred; the source is dead afterward). New in later programs; not in first guesses.
- `+x`: clone (copy). `*T` / `*Config(...)`: shared (refcounted) handle. New.
- Postfix `!` on a type/call = failure propagation, postfix `?` on a type = optional, `x?` on an expression = propagate none (p05 `digit(s[0])? * 100`, p11 `due? - today`). My `T?` guess was right; I had not guessed the expression form.
- `??` default, `as` unwrap-binding, `catch` all right. `catch |e|` block form may span lines (p10).
- Wrong or incomplete first guesses: bare arguments like `value(items)` are implicitly lent for reading (I was unsure); `sub` vs `fun` is not clearly about mutability (both take `!` params); `drop(!self)` is a destructor; `Box[T]`, `Text`, `match`, `enum`, `pass` and `@size` were new.

## Where I hesitated
- `not it.qty > 3` (p01 line 31): first read as `(not it.qty) > 3`; settled on `not (...)`.
- `(!ws).next() as w` and `(!q).next()`: the parenthesized `!` reads oddly; I took it as write lend of the receiver.
- `walk(root, !keys)` vs `walk(?n.left, !out)`: passing a bare value where a `?` view is expected looks inconsistent with having a `?` marker at all.
- `insert(!n.left if key < n.key else !n.right, key)` (p06): sigil inside a ternary, took a moment.
- `if !slot as n`, `if ?note as n`: `!`/`?` before the scrutinee means bind n as a write/read view.
- Trailing `!` on `sub transfer(...)!` vs `catch ... ` forms: initially thought `!` could mean "mutating".
- p07: whether `<web` as a bare statement drops it (and so prints `released base`) — resolved by reasoning about refcounts.
- r03: `cart.items.pop()` without `!` — not certain this is the one-line error vs the later use; chose line 14.
- Rendering of `none` and vectors when printed is guessed.

## Overall
7/10. The sigil set is small and mostly guessable (`?` read, `!` write, `<` move, `+` clone, postfix `!`/`?` for failure/none) and call sites show who may mutate, which made the "where is it modified" questions easy. Costs: `!` and `?` each carry two meanings depending on position (lend vs propagate/optional), `(!x).m()` parenthesized forms, implicit read lends on bare arguments, and `<x` as a bare statement being a drop all needed careful thought.
