# Cold reading of Rig

## First guesses (from p01, p02, p03 only)

Prefix symbols
- `&` before a type or expression (`it: &Item`, `&items[0]`, `for it in &items`, `report(&top)`): a read-only reference/borrow.
- `@` before a type or expression (`it: @Item`, `@items.push(...)`, `restock(@items[1], 5)`, `@ws.next()`): a mutable reference/borrow; the call site marks that the argument may be changed.
- `!` before an expression (`!in_stock(it)`, `!(it.qty > 3)`, `!bob.frozen`): logical not.
- `-` before a number (`-1`): negation.
- `@self` / `&self` is not in these three files.

Postfix symbols
- `?` after a type (`Int?`, `Entry?`, `&Entry?`): optional type, value or `none`.
- `!` after a return type (`-> Int!`): the function can fail with an error (result type).
- `!` after a parameter list (`sub transfer(...)!`): the subroutine can fail.
- `!` after a call (`withdraw(@from, n)!`, `transfer(@ann, @bob, 30)!`): "try": propagate the error to the caller, crashing/unwrapping at the top level in `main`.
- `??` (binary, after an expression): default if none (`find(...) ?? -1`).

Unrecognized keywords
- `fun`: a function that returns a value (last expression is the result).
- `sub`: a subroutine/procedure with no return value.
- `struct`: record type. `error`: declares an error set with named members (`Bank.frozen`).
- `use`: import. `none`: absent optional.
- `as` (`if find(...) as i`): unwrap an optional into a name inside the branch.
- `catch |e| ...` / `catch 0`: handle an error or give a fallback value.
- `and`, `or`: boolean operators. `Vec[T]`: generic vector.

## Answers

### p01
1. `32` (high)
2. `bolt 4` (high)
3. Lines 20, 21, 22 (push) and 26 (restock via `@items[1]`). Not 24 (`&` read) or 28 (`&items`). (high)
4. Line 32 runs once (only gear, qty 2, is not > 3; nut was restocked to 5). Line 33 prints `37 0`. (high; the `missing` count stays 0 since nut was restocked before the loop)

### p02
1. No. `find` takes `&Vec[Entry]`, a read view. (high)
2. Lines 16 and 18. (Line 15 only reads.) (high)
3. `top: cat 2` (high)
4. `6 3 -1` (high)

### p03
1. ann = 70, bob = 50. (high)
2. Prints `failed: insufficient` (exact rendering of the error, maybe `Bank.insufficient`, uncertain); no balance changes, since withdraw fails before the subtraction. (medium on format, high on no change)
3. Pass a failure on (propagate the error to the caller). (high)
4. `ann 70` then `bob 45`. (Line 33: `!bob.frozen` is false, so `report(ann)` runs, prints `ann 70`, and 70 != 70 is false, so line 34 does not print. Line 35 prints `bob 45`.) (high)

### p04
1. It lends `q` for writing: `next` removes the first job from `q.jobs`, so `q` changes. (high)
2. While the queue is not empty. (high)
3. `ran 1 5`, `ran 3 1`, `ran 4 0` (job 2 costs 7 > 5 and is skipped). (high)
4. `2 0 0 false` (high)

### p05
1. When `b` is not a digit character. (high)
2. Yes, `pos` is a write-lent `@Int`, and `number` advances it. (high)
3. `49` (high)
4. `-1 -2` (high)

### p06
1. Lines 33 (once per iteration) and 38. (high)
2. `walk` cannot modify `root` (read view) but can modify `keys` (write lend). (high)
3. `[20, 30, 40, 50, 70] 210` (list formatting medium)
4. Yes, line 38 runs (45 is not in the tree). Line 39 prints `255 true`. (high)

### p07
1. `2 2` (high)
2. No. `web` and `db` still hold handles to base. (high)
3. Line 25 (`<web`), which drops the last remaining handle to base, since `db.config` was reassigned on line 23. (high)
4. `db` (moved into the vec on line 28). (high)

### p08
1. `2 3` (high)
2. No. `+log.lines` makes an independent copy. (high)
3. `log` (moved by `archive(<log)`). (high)
4.
```
archive app.log 2
close app.log
after archive
close tmp
end 3
close app.bak
```
(high; `close app.bak` happens when `backup` goes out of scope at the end of main)

### p09
1. Yes: `shapes[1]` becomes rect with w=5, h=8 (w += 2, h *= 2). (high)
2. `12`, `40`, `0` (one per line). (high)
3. `big circle 2` (high)
4. `400 false` (Pixel is four U8 = 4 bytes; medium-high on `$size`)

### p10
1. The top of `stack` is removed (popped), if there is one. (high)
2. Failure propagation. (high)
3. Line 33 prints `14`; line 34 prints `2`. (high)
4. Line 35 prints `-1 -2`; line 39 prints `6`. (high)

### p11
1. `none` (the postpone on the `none` due does nothing). (high)
2. `rent -4`, `call -1`, `taxes 20` (taxes' due was postponed 15 to 25). (high)
3. `2 8` (high)
4. Yes: `pop` removes the last task. Line 33 prints `dropped taxes 25` and line 34 prints `2`. (high)

### p12
1. No. `+players` is an independent clone. (high)
2. Lines 20, 21, 28 (through `bump(@p.score, ...)`, within the write-lent loop of line 27), 29 and 30 (through `target`, a write lend of an element). (medium-high on exactly which lines to count; 27 sets up the write loan)
3. When neither player is alive (both have lives <= 0). (high)
4. Line 32: `4 ana 10`; line 33: `0 true`. (high)

### r01-r04
- r01: line 11. `charge` takes `a: &Account` (read only) but assigns `a.balance -= n`. (high)
- r02: line 18. `r` was moved by `archive(<r)` on line 16, then `r.pages.len` uses it. (high)
- r03: line 14. `cart.items.pop()` mutates the vector without the `@` write marker (should be `@cart.items.pop()`). (medium-high)
- r04: line 14 (the `@list.push`, which could reallocate or change `list` while the read view `top` from line 13 is still used on line 15; line 15 is where it would dangle). (medium on 14 vs 15)

## Revised meanings

- `&x` / `&T`: lend for reading (read view). `@x` / `@T`: lend for writing. Both mark the call site as well as the parameter type. `&self` and `@self` are the method forms. Confirmed from my guesses, with a refinement: implicit read lending appears, since `walk(root, @keys)` and `value(items)` pass without `&`.
- `<x`: move (ownership transfer). A new one not guessed in step 1; it also acts as an explicit "drop now" when written as a bare statement (`<tmp`, `<base`).
- `+x`: clone (`+log.lines`, `+base`, `+players`). In `*Config` / `*T`, `*` is a shared (refcounted) handle. `*Config(...)` creates one.
- `!x` prefix: logical not. Postfix `!` on an expression: propagate failure (try). `T!`: fallible type. Postfix `!` after a parameter list: the sub is fallible.
- `T?`: optional; `x?` postfix: propagate `none`/unwrap (`digit(s[0])? * 100`). `??` default. `x ?? return ...` also works.
- `as`: bind unwrap in `if x as n`. `if @slot as n` and `if &note as n` lend while unwrapping.
- `Box[T]`: owned heap box. `catch |e|` handles errors. `$size(T)`: builtin size. `drop(@self)`: destructor hook. `pass`: no-op.

Wrong first guesses: I did not consider `<`, `+`, `*` as prefix sigils (they did not appear in p01-p03). I thought `@` only meant "mutable reference" and not clearly "lend for writing, distinct from move". I thought `!` after a call crashes at top level; it just propagates to the caller (main is fallible-allowed or it traps).

## Where I hesitated

- `+log.lines` (p08 line 21): first read as addition or unary plus; context (constructor argument, and `log` used afterwards) shows clone.
- `<log` (p08 line 24, p07): first read as a stray comparison; it is a move.
- Bare `<tmp` / `<base` statements: I wondered what they do (a move into nothing means drop/release).
- p03 line 17: `withdraw(@from, n)!`; trailing `!` could be negation of the result, a write marker, or propagation. Resolved by the `)!` on the `sub` header and the `-> Int!` type.
- p05 line 31 `digit(s[0])? * 100`: `?` as postfix unwrap-or-return-none, not a ternary.
- p05 line 15 `?? return Parse.bad`: `return` as the right-hand side of `??`.
- p06 lines 35 and 37: `walk(root, ...)` without `&` versus `contains(&root, 45)` with `&`; I took it to mean the sigil is optional for reads.
- p06 line 8: `@n.left if key < n.key else @n.right` as an expression-valued conditional passing lends.
- p02 line 33-34: `top = e` assigns a view into an `Entry?`; I accepted it.
- p12: which lines "modify players" through `for p in @players`, `target = @players[...]`.
- r04: whether the error is at the push (14) or the use (15).
- Output formatting of lists, errors and optionals (`[20, 30, ...]`, `failed: insufficient`, `none`) is guessed.

## Overall

7/10. The sigils are mostly consistent, and the `@` and `&` at the call site make mutation easy to spot (more than in most languages). The structure reads like Python. The costs were the overloaded `!` (not, try, fallible type), `?`, and the unfamiliar prefix `<` and `+` for move and clone, which need a program that uses them to decode. Once the pattern is known, ownership flow is quick to trace.
