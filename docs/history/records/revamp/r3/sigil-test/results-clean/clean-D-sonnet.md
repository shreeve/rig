# Rig: first-contact read

## First guesses
These are my reading after p01–p03 only.

**Prefix symbols**
- `&` before a type or expression (`it: &Item`, `&items[0]`, `&entries`): a read-only borrow or reference.
- `@` before a type (`it: @Item`): a mutable reference parameter, one the function may write through.
- `@` before an expression (`@items.push(...)`, `restock(@items[1], 5)`, `withdraw(@from, n)`): "lend this for writing". It marks the call site where a mutation can happen. The method form `@items.push` marks that the receiver is mutated.
- `@ws.next() as w`: the same marker. The call mutates the iterator.
- `!` before an expression (`!in_stock(it)`, `!(it.qty > 3)`): boolean not.

**Postfix symbols**
- `?` after a type (`Int?`, `Entry?`): optional, either a value or `none`.
- `!` after a return type (`-> Int!`): the function may fail with an error value.
- `!` after a bare `sub` signature (`sub transfer(...)!`): the same, with no result value.
- `!` after a call (`withdraw(@from, n)!`, `transfer(...)!`): if the call failed, pass the failure on to my caller. Otherwise unwrap the result. I was fairly sure of this, because the enclosing function is itself declared with `!`.
- `??` between two expressions (`find(...) ?? -1`): a default value when the left side is `none`.

**Keywords I didn't know**
- `fun`: a function that returns a value, probably pure or read-mostly.
- `sub`: a procedure with no return value, probably allowed to mutate.
- `struct`: a record type.
- `error Bank` with variants: an error enum.
- `use std.text`: import.
- `as` in `if x as i`: if the optional has a value, bind it to `i`. It is not a cast.
- `catch |e| ...` and `catch 0`: handle a failure, either with the error bound as `e` or with a fallback value.
- `none`: the empty optional.
- `and` / `or`: boolean operators.
- `Vec[Item]`: a generic vector.
- `return X if cond`: a postfix conditional return.
- Indentation defines blocks.
- The last expression of a function is its value.

## Answers

### p01 — inventory
1. Line 23 prints `32` (4·3 + 0·1 + 2·10). Confidence: high.
2. Line 25 prints `bolt 4`. Confidence: high.
3. `items` may be modified on lines 20, 21, 22 (`push`) and 26 (`restock(@items[1], 5)`). Line 28 (`for it in &items`) is read-only. Confidence: high.
4. Line 32 runs once, for `gear` (qty 2), and prints `low: gear`. Bolt has 4 and nut has 5 after the restock. Line 33 prints `37 0` (12 + 5 + 20, and no item has qty 0). Confidence: high.

### p02 — word counter
1. No. `find` takes `&Vec[Entry]`, which is read-only. Confidence: high.
2. Line 16 (`entries[i].count += 1`) and line 18 (`@entries.push`). Line 15 only reads. Confidence: high.
3. `top: cat 2`. Confidence: high. The counts are the 3, cat 2, and saw/dog/and/ran 1 each. The last entry with count ≠ 1 that isn't "the" is `cat`.
4. `6 3 -1`. Confidence: high. There are 6 distinct words, in the order the, cat, saw, dog, and, ran. So `dog` is at index 3 and `cow` is `none`, which becomes -1.

### p03 — bank ledger
1. ann = 70, bob = 50. Confidence: high.
2. Line 28 prints `failed: insufficient`. The exact error text may be `Bank.insufficient`, which is a formatting detail I can't confirm. No balance changes, because the withdraw fails before `a.balance -= n`. Confidence: high on the failure, medium on the exact text.
3. It passes a failure on (propagates it to the caller). Confidence: high.
4. Line 33 does not print `check ann`: `!bob.frozen` is false, `report(ann)` prints `ann 70` and returns 70, and 70 != 70 is false. Line 35 prints `bob 45`. The output is `ann 70`, then `bob 45`. Confidence: high.
   - Line 32 prints `failed: frozen`, also with the error-text caveat.
   - Line 29 sets `left` to 45.

### p04 — job queue
1. It removes the first job from the queue's `jobs` and returns it, so `q` is mutated. Confidence: high.
2. The loop keeps going while the queue is not empty (`!q.is_empty()`). Confidence: high.
3. Confidence: high.
   ```
   ran 1 5
   ran 3 1
   ran 4 0
   ```
   Job 2 (cost 7 > 5) is skipped.
4. `2 0 0 false`. Confidence: high. The values are the retry id, `skipped.len` after the remove, `q.jobs.len`, and `budget != 0`.

### p05 — expression parser
1. When `b` is not a digit character (`text.is_digit(b)` is false). Confidence: high.
2. Yes. `pos` is an `@Int` (writable reference), so `pos += 1` inside `number` changes the caller's `pos`. Confidence: high.
3. Line 35 prints `-1 -2`. Confidence: high. "4+x" fails with `Parse.bad` and "5++6" fails with `Parse.empty`.
4. Line 36 prints `700 none 0`. Confidence: medium. The values 700 and 0 are certain. How an absent optional is printed (`none`) is a guess.
   - Line 34 prints `49`.

### p06 — binary tree
1. Lines 33 and 38 (`insert(@root, ...)`). Confidence: high.
2. `walk` may not modify `root`, which is passed read-only (`&Box[Node]?`). It may modify `keys`, which is passed as `@keys`. Confidence: high.
3. `[20, 30, 40, 50, 70] 210`. Confidence: high (the list's print format is medium).
4. Yes, line 38 runs, because 45 is not in the tree and `!contains` is true. Line 39 prints `255 true`. Confidence: high.

### p07 — shared configuration
1. `2 2`. Confidence: high.
2. No. Line 20 only gives up the `base` handle, and `web` and `db` still share the config. Confidence: high.
3. Line 25 (`<web`). It drops the last remaining handle to `base`, which prints `released base`. Confidence: medium-high. Line 23, which reassigns `db.config`, removes `db`'s handle, but `web` still holds one.
4. `db` can't be used after line 28, since `<db` moved it into `running`. `base` and `web` were already unusable after lines 20 and 25. Confidence: high.
   - `released debug` should print after `end of main`.

### p08 — files
1. `2 3`. Confidence: high.
2. No. `+log.lines` makes an independent copy, so appending "copied" to `backup` doesn't touch `log`. Confidence: medium-high.
3. `log`, because `<log` moves it into `archive`. Confidence: high.
4. Confidence: high.
   ```
   archive app.log 2
   close app.log
   after archive
   close tmp
   end 3
   close app.bak
   ```
   The `drop` runs when `archive` ends, when `<tmp` consumes `tmp`, and when `main` ends.

### p09 — shapes
1. Yes. `shapes[1]` becomes `rect(w: 5, h: 8)`: `w += 2` and `h *= 2`. Confidence: high.
2. Three lines: `12`, `40`, `0`. Confidence: high.
3. `big circle 2`. Confidence: high.
4. `400 false`. Confidence: high (`$size(Pixel)` is 4 bytes).

### p10 — stack calculator
1. The last element is popped off (removed from `stack`), so the stack shrinks by one. Confidence: high.
2. Failure propagation. Confidence: high.
3. Line 33 prints `14`. Line 34 prints `2`. Confidence: high.
4. Line 35 prints `-1 -2`. Line 39 prints `6`. Confidence: high. "9 +" underflows, and "1 2" leaves a leftover value. Line 36's handler never runs.

### p11 — task list
1. `none`. `postpone` does nothing when the due date is `none`. Confidence: high.
2. Confidence: high.
   ```
   rent -4
   call -1
   taxes 20
   ```
3. `2 8`. Confidence: high.
4. Yes, `pop` removes the last task. Line 32 prints `dropped taxes 25`, and line 34 prints `2`. Confidence: high.

### p12 — game
1. No. `+players` makes an independent copy (snapshot). Confidence: medium-high.
2. Writes happen on lines 20 and 21 (`push`), 28 (`bump(@p.score, ...)`, inside the `for p in @players` that starts on 27) and 30 (`target.lives -= 1`, where `target` was taken writable on 29). Lines 27 and 29 are where write access is taken. Confidence: high.
3. `done` is true when neither player is alive, meaning both have lives ≤ 0. That is after round 4. Confidence: high.
4. Line 32 prints `4 ana 10`. Line 33 prints `0 true`. Confidence: high.

### Rejected programs
- **r01**: line 11. `a.balance -= n` writes through `a: &Account`, which is read-only. It would need `@Account`. Confidence: high.
- **r02**: line 18. `r.pages.len` uses `r` after `<r` moved it on line 16. Confidence: high.
- **r03**: line 14. `cart.items.pop()` mutates without the `@` marker (`@cart.items.pop()`). Confidence: high.
- **r04**: line 14. `list.push` mutates `list` while `top` (a `&` borrow from line 13) is still used on line 15. Confidence: medium. The compiler could flag line 15 instead.

## Revised meanings
- `&`: read-only borrow, as guessed. At call sites it is optional, because `walk(root, ...)` and `walk(&root, ...)` both appear.
- `@`: writable borrow, as guessed. At call sites it is required wherever the callee mutates. It also marks `@self` methods and `@x.method()` calls that mutate, even for `pop`/`remove` that return values.
- `!` prefix: negation, as guessed. `!` postfix on a type or signature means "can fail". `!` after a call propagates the failure. That was right.
- `?` postfix on a type: optional, as guessed. `?` postfix on an expression (`digit(...)? * 100`, `due? - today`) was new: if `none`, return `none` from the enclosing function. Otherwise unwrap the value.
- `*Type`: a shared, reference-counted owning handle. I didn't see it in p01–p03, so this is new.
- `+x`: copy (clone) of a value, or a new shared handle for `*` types. New.
- `<x`: move or consume. After `<x`, `x` is dead, and a bare `<tmp` statement drops it. New.
- `drop(@self)`: a destructor. New.
- `$size(T)`: a compile-time size query. New.
- `x as n` in an `if`: binds the unwrapped value, as guessed. It works on `@x` and `&x` too, giving a writable or read-only binding.
- `??`: default, as guessed. `?? return Parse.bad` also works as an early-exit form.
- `catch`: handles a failure, as guessed. It takes an optional `|e|` binding and a value or block.
- `fun` and `sub`: the guess held (`fun` returns a value, `sub` doesn't). But `fun` can take `@` parameters (`withdraw`, `take`), so `fun` is not pure.
- `continue`, `pass`, `match`, `enum` and `.variant(x)` patterns, `0..n` ranges, `Box[T]` and `Text` were new in later files.

## Where I hesitated
- **`@` before call arguments that are already `@` parameters** (`withdraw(@from, n)`, `add(@entries, w)`): I first wondered whether `@` meant "re-borrow" or "address-of". I settled on a re-lend marker.
- **p02 line 15**: `find(entries, w)` has no `&` while `entries` is `@Vec`. I had to decide it passes a read-only view, not a lend for writing.
- **p03 line 17, trailing `!`**: I briefly considered it as negation, but the signature's trailing `!` settled it.
- **p05 line 14**: `s[pos]` compared to `43`. It took me a moment to see that bytes are compared as integers (43 is `+`). On line 9, `Int(b) - 48` confirmed it.
- **p05 line 12**: `start = pos` where `pos` is `@Int`. I read it as copying the integer value, not aliasing the reference.
- **p05 line 31**: `digit(...)? * 100`. I first read `?` as part of a type or as a ternary. It's the early-return-on-none operator.
- **p06 line 8**: `@n.left if key < n.key else @n.right` as an argument. I first thought `@` was part of a statement-form `if`. It's a conditional expression whose branches are lent places.
- **p07, `+base` and `<base`**: I first thought `<base` released the config. It only drops one handle. I had to count handles to answer question 2.
- **p08, `+log.lines`**: I first read it as moving the vector, or sharing it. The `count` output depends on it being a copy.
- **p09 line 19, `match @s`**: I first thought `@` here meant a pattern. It lends the scrutinee so the bindings (`r`, `w`, `h`) are writable.
- **p12 line 22, `+players` vs p07's `+base`**: the same symbol on a `*` handle and on a plain Vec. I had to infer a common meaning, "make another one".
- **r04**: I wasn't sure whether the compiler reports line 14 or 15.
- **Printing of `none` and of error values**: the exact text is a guess.

## Overall
**Rating: 7/10.**

- **Readable**: the ownership-and-mutation story shows at nearly every call site through `&`, `@`, `<` and `+`. For the p01–p04 style of program, I could tell which lines mutate without reading any callee. Indentation and the `fun`/`sub`/`struct` keywords are familiar.
- **Hard cold**: the symbols overload. `!` is negation, "can fail" and "propagate". `?` is an optional type and an early-return operator. `+` and `<` have no precedent in common languages, so I could only learn them from the p07/p08 outputs and the r02 rejection. The `*` handle and its reference-count semantics had to be deduced from the `drop` messages.
- **Unclear**: output formats for `none`, errors and Vec.
